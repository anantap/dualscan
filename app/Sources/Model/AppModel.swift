import Foundation
import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class AppModel {
    enum Connection: Equatable {
        case searching            // waiting for the scanner on USB
        case opening              // driver opens it: lamp + calibration
        case warmingUp(until: Date)
        case ready
        case failed(String)
    }

    enum Scope: Hashable { case roll, frame }

    // Scanner
    var connection: Connection = .searching
    var useSimulator = false
    private(set) var scanner: ScannerDevice?
    /// What the connected scanner can do; the settings card and the stage follow it.
    private(set) var capabilities = ScannerCapabilities.dualIV
    var holderIn = false
    var connectedAt: Date?
    var warmupStarted: Date?

    // Roll
    var rollName = "Roll 01"
    /// Where scans are kept while you work: ~/Pictures/Dual Scan/<date> <roll>.
    var libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Dual Scan", isDirectory: true)
    let day = Date().formatted(.iso8601.year().month().day())
    var rollFolder: URL { libraryRoot.appendingPathComponent("\(day) \(rollName)", isDirectory: true) }
    /// Where exports go; chosen in the export sheet, the roll folder by default.
    private var chosenExportFolder: URL?
    var folder: URL {
        get { chosenExportFolder ?? rollFolder }
        set { chosenExportFolder = newValue }
    }
    var film: FilmType = .color { didSet { (scanner as? SimulatedScanner)?.film = film; rerenderAll() } }
    var extraWarmupMinutes: Int {
        didSet { UserDefaults.standard.set(extraWarmupMinutes, forKey: "extraWarmup") }
    }
    /// The strip in the holder.
    private(set) var frames: [Frame] = AppModel.strip(1)
    /// Which strip of the roll is in the holder (1, 2, …).
    private(set) var stripNumber = 1
    /// Scanned frames of the strips before this one; their raw files hold the full scans.
    private(set) var earlierScans: [Frame] = []

    static func strip(_ n: Int) -> [Frame] {
        (1...6).map { Frame(number: (n - 1) * 6 + $0, position: $0) }
    }

    /// After a strip with scans comes out, the next one continues the numbering
    /// (07–12, …), so its files never overwrite the previous strip's.
    private func startNextStrip() {
        for f in frames where f.isScanned || f.phase == .scanning {
            if f.rawURL != nil { f.full = nil }   // the raw file has it; keeps memory down over a roll
            earlierScans.append(f)
        }
        stripNumber += 1
        frames = Self.strip(stripNumber)
        selection = [0]
        selectedIndex = 0
    }
    var selectedIndex = 0
    var selection: Set<Int> = [0]
    var selected: Frame { frames[selectedIndex] }

    // Scanning
    var rollSettings = ScanSettings()
    var settingsScope: Scope = .roll
    var previewRunning = false
    var queueRunning = false
    var pauseRequested = false
    var activeFrame: Frame?

    // Editing
    /// Density of the film base per channel, used for the whole roll.
    var filmBase: [Double]?
    var baseSource: BaseSource = .measured
    enum BaseSource: Equatable { case measured, picked, stock(String) }
    var baseFromPicker: Bool { baseSource != .measured }
    /// What a click on the image does.
    enum Picking { case base, neutral }
    var picking: Picking?
    /// Film bases saved per film stock, e.g. "Portra 400".
    var savedStocks: [String: [Double]] = (UserDefaults.standard.dictionary(forKey: "filmStocks") as? [String: [Double]]) ?? [:] {
        didSet { UserDefaults.standard.set(savedStocks, forKey: "filmStocks") }
    }
    var showPositivePreview = false
    var showBefore = false
    var showExport = false
    /// Whether the export sheet exports the whole roll or the selection.
    var exportWholeRoll = false
    /// Frames done and total while an export runs.
    var exportProgress: (done: Int, total: Int)?
    var message: String?

    init() {
        let saved = UserDefaults.standard.object(forKey: "extraWarmup") as? Int
        extraWarmupMinutes = saved ?? 2
    }

    // MARK: - Derived

    var queue: [Frame] { frames.filter { $0.phase == .queued } }
    var scannedCount: Int { frames.filter(\.isScanned).count }
    var previewedCount: Int { frames.filter { $0.phase != .empty && $0.phase != .previewing }.count }
    var hasPreviews: Bool { frames.contains { $0.preview != nil } }

    func settings(for f: Frame) -> ScanSettings { capabilities.fitting(f.ownSettings ?? rollSettings) }
    func edit(for f: Frame) -> EditSettings { f.edit }

    /// Binding target for the scan settings card.
    var shownSettings: ScanSettings {
        get { settingsScope == .frame ? (selected.ownSettings ?? rollSettings) : rollSettings }
        set {
            if settingsScope == .frame {
                for f in selectedFrames where !f.isScanned { f.ownSettings = newValue }
            } else { rollSettings = newValue }
        }
    }

    /// Binding target for the edit cards. With several frames selected, a
    /// change goes to all of them: the setting that moved gets the new value
    /// everywhere, the other settings stay as each frame had them.
    var shownEdit: EditSettings {
        get { selected.edit }
        set { setEdit(newValue, syncSelection: true) }
    }

    func setEdit(_ e: EditSettings, syncSelection: Bool) {
        let old = selected.edit
        selected.edit = e
        render(selected)
        guard syncSelection else { return }
        for f in editTargets where f !== selected {
            f.edit = f.edit.applying(changesFrom: old, to: e)
            render(f)
        }
    }

    /// Selected frames that have an image to edit.
    var editTargets: [Frame] { selectedFrames.filter { $0.display != nil } }

    /// "Frame 03" or "3 frames".
    var editTargetLabel: String {
        let n = max(1, editTargets.count)
        return n == 1 ? "Frame \(selected.name)" : "\(n) frames"
    }

    /// The base edit copied with ⇧⌘C.
    var copiedEdit: EditSettings?

    func copyEdit() { copiedEdit = selected.edit }

    /// Pastes the copied base edit on every selected frame.
    func pasteEdit() {
        guard let e = copiedEdit else { return }
        for f in editTargets { f.edit = e; render(f) }
    }

    /// Gives every other scanned frame the selected frame's base edit.
    func copyEditToAll() {
        for f in frames where f !== selected && f.editSource != nil { f.edit = selected.edit; render(f) }
    }

    // MARK: - Connecting

    func start() {
        SaneSession.configure()
        if CommandLine.arguments.contains("--simulate-dual-iii") {
            useSimulator = true
            simulatedModel = .dualIII
            extraWarmupMinutes = 0
        }
        if CommandLine.arguments.contains("--simulate") || CommandLine.arguments.contains("--selftest") {
            useSimulator = true
            extraWarmupMinutes = 0
        }
        Task { await connect() }
    }

    /// Which model the simulator plays.
    @ObservationIgnored var simulatedModel = ScannerCapabilities.dualIV

    func useSimulatedScanner() {
        useSimulator = true
        if case .searching = connection { } else { return }
    }

    private func connect() async {
        connection = .searching
        var device: ScannerDevice?
        while device == nil {
            if useSimulator {
                device = SimulatedScanner(film: film, capabilities: simulatedModel)
                break
            }
            let found: (name: String, model: String)? = await withCheckedContinuation { c in
                SaneSession.queue.async { c.resume(returning: SaneSession.findScanner()) }
            }
            if let found {
                device = SaneScanner(deviceName: found.name, displayName: found.model)
            } else {
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let device else { return }
        scanner = device
        connection = .opening
        warmupStarted = Date()
        do {
            try await device.open()
        } catch {
            connection = .failed(error.localizedDescription)
            return
        }
        capabilities = device.capabilities
        rollSettings = capabilities.fitting(rollSettings)
        connectedAt = Date()
        let until = Date().addingTimeInterval(Double(extraWarmupMinutes) * 60)
        connection = .warmingUp(until: until)
        while Date() < until, case .warmingUp = connection {
            try? await Task.sleep(for: .milliseconds(250))
        }
        connection = .ready
        await waitForHolder()
    }

    func skipWarmup() {
        if case .warmingUp = connection { connection = .ready }
    }

    func retryConnection() {
        Task { await connect() }
    }

    private func waitForHolder() async {
        guard let scanner else { return }
        while !(await scanner.holderPresent()) {
            try? await Task.sleep(for: .seconds(1.5))
        }
        holderIn = true
        await previewAll()
    }

    func eject() {
        guard let scanner, !queueRunning, !previewRunning else { return }
        Task {
            do { try await scanner.eject() } catch { message = error.localizedDescription }
            holderIn = false
            if frames.contains(where: \.isScanned) {
                startNextStrip()
            } else {
                for f in frames { f.reset() }   // nothing scanned: the same strip can go back in
            }
            await waitForHolder()
        }
    }

    // MARK: - Preview

    func previewAll() async {
        guard let scanner, !previewRunning else { return }
        previewRunning = true
        defer { previewRunning = false; activeFrame = nil }
        for f in frames where f.phase == .empty {
            f.phase = .previewing
            f.progress = 0
            activeFrame = f
            do {
                let result = try await scanner.scan(ScanRequest(frame: f.position, settings: rollSettings, preview: true)) { p in
                    Task { @MainActor in f.progress = p }
                }
                f.preview = result.image
                f.lastExposure = result.exposure
                f.phase = .previewed
                await prepare(f, from: result.image)
                if f.histogram.map(isBlank) ?? false { f.skipped = true }
            } catch ScannerError.cancelled {
                f.phase = .empty
                return
            } catch {
                f.phase = .empty
                f.error = error.localizedDescription
                message = error.localizedDescription
                return
            }
        }
        estimateFilmBase()
    }

    /// Unexposed film: almost no spread in density.
    private func isBlank(_ h: Converter.Histogram) -> Bool {
        guard h.total > 0 else { return true }
        let lo = Converter.percentile(h.counts[1], total: h.total, 0.02)
        let hi = Converter.percentile(h.counts[1], total: h.total, 0.98)
        return hi - lo < 0.08
    }

    func stopPreview() { scanner?.cancel() }

    // MARK: - Queue

    func addToQueue(_ f: Frame) {
        guard f.phase == .previewed, !f.skipped else { return }
        f.phase = .queued
    }

    func addAllToQueue() {
        for f in frames where f.phase == .previewed && !f.skipped { f.phase = .queued }
    }

    func removeFromQueue(_ f: Frame) {
        if f.phase == .queued { f.phase = .previewed }
    }

    func clearQueue() {
        for f in frames where f.phase == .queued { f.phase = .previewed }
    }

    func startQueue() {
        guard !queueRunning, !previewRunning else { return }
        Task {
            // When the queue has scanned everything on the strip, the strip comes out by itself.
            if await runQueue(), autoEject, !stripHasMoreToScan { eject() }
        }
    }

    /// Eject the strip after the queue finishes it (the self-test turns this off for a while).
    @ObservationIgnored var autoEject = true

    /// A frame on the strip that isn't scanned and isn't skipped (ring): ejecting now would
    /// mean putting the strip back in for it.
    var stripHasMoreToScan: Bool {
        frames.contains { !$0.skipped && !$0.isScanned && $0.phase != .scanning }
    }

    func pauseQueue() { pauseRequested = true }

    /// When the scanner last delivered a frame, to measure how long it waits.
    @ObservationIgnored private var lastScanEnded: Date?

    /// Scans the queue; true when it ran out (not paused, no error), with every scan saved.
    private func runQueue() async -> Bool {
        guard let scanner else { return false }
        queueRunning = true
        pauseRequested = false
        defer { queueRunning = false; activeFrame = nil; pauseRequested = false }
        // Frames added while the queue runs are picked up too.
        while !pauseRequested, let f = frames.first(where: { $0.phase == .queued }) {
            f.phase = .scanning
            f.progress = 0
            activeFrame = f
            if let t = lastScanEnded { SelfTest.log(String(format: "scanner idle between frames: %.0f ms", Date().timeIntervalSince(t) * 1000)) }
            do {
                let result = try await scanner.scan(ScanRequest(frame: f.position, settings: settings(for: f), preview: false)) { p in
                    Task { @MainActor in f.progress = p }
                }
                lastScanEnded = Date()
                f.full = result.image
                f.lastExposure = result.exposure
                f.lastFocus = result.focus
                // Saving and the editing copy happen next to the next scan,
                // so the scanner never waits for them.
                Task { await finishScan(f, result.image) }
            } catch ScannerError.cancelled {
                f.phase = .queued
                return false
            } catch {
                f.phase = .queued
                f.error = error.localizedDescription
                message = error.localizedDescription
                return false
            }
        }
        if pauseRequested { return false }
        // The last frames are still being saved; they go with the strip only once they're done.
        while frames.contains(where: { $0.phase == .scanning }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    private func finishScan(_ f: Frame, _ image: Image16) async {
        f.fullSize = (image.width, image.height)
        await saveRaw(f, image)
        f.proxy = await Task.detached(priority: .userInitiated) { image.downscaled(maxEdge: AppModel.editEdge) }.value
        await prepare(f, from: f.proxy!)
        f.phase = .scanned
    }

    private func saveRaw(_ f: Frame, _ img: Image16) async {
        let url = rollFolder.appendingPathComponent("Raw/\(fileStem(f))_raw.tif")
        do {
            try await Task.detached {
                try ImageFiles.writeTIFF16(img.data, width: img.width, height: img.height, to: url, linear: true)
            }.value
            f.rawURL = url
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Conversion

    /// Histogram, negative images and first positive for a fresh scan or preview.
    private func prepare(_ f: Frame, from img: Image16) async {
        // Measured once per source, off the main thread.
        (f.histogram, f.baseEstimate) = await Task.detached { (Converter.histogram(img), Converter.estimateBase(img)) }.value
        estimateFilmBase()
        await updateSources(f)
        rerenderAll()
    }

    /// The thinnest density over all frames: the film base. Blank frames
    /// (unexposed film) count too, and are the best sample there is.
    private func estimateFilmBase() {
        guard baseSource == .measured else { return }
        let bases = frames.compactMap(\.baseEstimate)
        guard !bases.isEmpty else { return }
        filmBase = (0..<3).map { c in bases.map { $0[c] }.min()! }
    }

    /// Handles a click on the image while picking; `point` is 0...1 in the shown image.
    func pick(atUnit point: CGPoint) {
        guard let mode = picking, let rotated = selected.display else { return }
        let x = min(rotated.width - 1, Int(point.x * Double(rotated.width)))
        let y = min(rotated.height - 1, Int(point.y * Double(rotated.height)))
        let r = max(2, min(rotated.width, rotated.height) / 200)
        let D = Converter.sampleDensity(rotated, x: x, y: y, radius: r)
        picking = nil
        switch mode {
        case .base:
            filmBase = D
            baseSource = .picked
            rerenderAll()
        case .neutral:
            // Balance this frame so the clicked spot comes out grey.
            let n = Converter.normalized(analysis(for: selected), D, positive: film == .slide)
            let m = (n[0] + n[1] + n[2]) / 3
            var e = selected.edit
            e.wb = n.map { m - $0 }
            e.temp = 0
            e.tint = 0
            // The grey spot belongs to this photo, so only this frame changes.
            setEdit(e, syncSelection: false)
        }
    }

    func resetBase() {
        baseSource = .measured
        filmBase = nil
        estimateFilmBase()
        rerenderAll()
    }

    func useStock(_ name: String) {
        guard let b = savedStocks[name] else { return }
        filmBase = b
        baseSource = .stock(name)
        rerenderAll()
    }

    func saveStock(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let b = filmBase else { return }
        savedStocks[name] = b
        baseSource = .stock(name)
    }

    func deleteStock(_ name: String) {
        savedStocks[name] = nil
        if baseSource == .stock(name) { resetBase() }
    }

    /// The conversion is shared by the whole roll.
    func analysis(for f: Frame) -> Converter.Analysis { rollAnalysis() }

    func rollAnalysis() -> Converter.Analysis {
        let hist: Converter.Histogram?
        do {
            let scanned = frames.filter { $0.isScanned }.compactMap(\.histogram)
            let pool = scanned.isEmpty ? frames.filter { !$0.skipped }.compactMap(\.histogram) : scanned
            hist = pool.isEmpty ? nil : Converter.Histogram.merged(pool)
        }
        return Converter.analyze(hist, base: filmBase)
    }

    /// Long edge of the editing copy of a scan: sharp on the stage of a Retina screen.
    nonisolated static let editEdge = 2400
    /// Long edge of the strip thumbnails.
    nonisolated static let thumbEdge = 480

    /// Makes the turned stage and strip copies of a frame and its negative
    /// images. Runs when the source or the rotation changes, not per render.
    func updateSources(_ f: Frame) async {
        guard let src = f.editSource else { return }
        let rotation = f.rotation
        let (display, thumb, negative, negativeThumb) = await Task.detached(priority: .userInitiated) {
            let d = src.rotated(rotation)
            let t = d.downscaled(maxEdge: AppModel.thumbEdge)
            return (d, t, d.negativeCGImage(), t.negativeCGImage())
        }.value
        // A newer source or rotation may have arrived meanwhile.
        guard f.editSource?.width == src.width, f.rotation == rotation else { return }
        f.display = display
        f.thumb = thumb
        f.negativeImage = negative
        f.negativeThumb = negativeThumb
        f.positiveStale = true
        render(f)
    }

    /// Redraws every frame after a roll-wide change. Only the selected frame
    /// renders at stage size; the rest only redraw their thumbnail.
    func rerenderAll() {
        let an = rollAnalysis()
        for f in frames where f.display != nil { render(f, analysis: an) }
    }

    private var rendering: Set<Int> = []
    private var renderAgain: Set<Int> = []
    private var renderCounter = 0

    /// At most one render per frame runs at a time. Changes that arrive while
    /// one runs are drawn right after it, with the newest settings, so a fast
    /// slider never piles up work and the image keeps following it.
    func render(_ f: Frame, analysis given: Converter.Analysis? = nil) {
        guard f.display != nil else { return }
        renderCounter += 1
        f.requestedRender = renderCounter
        if rendering.contains(f.number) { renderAgain.insert(f.number); return }
        rendering.insert(f.number)

        let ticket = renderCounter
        let params = Converter.params(given ?? rollAnalysis(), f.edit, film: film)
        let display = f === selected ? f.display : nil
        let thumb = f.thumb
        Task {
            let (big, small) = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                func draw(_ img: Image16?) -> CGImage? {
                    img.flatMap { CGImage.rgba8(Converter.render8($0, params), width: $0.width, height: $0.height) }
                }
                return (draw(display), draw(thumb))
            }.value
            if let big { f.positiveImage = big; f.positiveStale = false } else { f.positiveStale = true }
            if let small { f.positiveThumb = small }
            f.shownRender = ticket
            rendering.remove(f.number)
            if renderAgain.remove(f.number) != nil || (f === selected && f.positiveStale) { render(f) }
        }
    }

    func rotateSelected() {
        let f = selected
        f.rotation = (f.rotation + 270) % 360
        Task { await updateSources(f) }
    }

    func setSettingsScope(_ s: Scope) {
        settingsScope = s
        for f in selectedFrames where !f.isScanned {
            if s == .frame, f.ownSettings == nil { f.ownSettings = selected.ownSettings ?? rollSettings }
            if s == .roll { f.ownSettings = nil }
        }
    }

    /// Click selects one frame; ⌘-click adds or removes; ⇧-click selects a range.
    func select(_ i: Int, modifiers: EventModifiers = []) {
        if modifiers.contains(.command) {
            if selection.contains(i), selection.count > 1 {
                selection.remove(i)
                if selectedIndex == i { selectedIndex = selection.sorted().first! }
            } else {
                selection.insert(i)
                selectedIndex = i
            }
        } else if modifiers.contains(.shift) {
            let r = min(i, selectedIndex)...max(i, selectedIndex)
            selection.formUnion(r)
            selectedIndex = i
        } else {
            selection = [i]
            selectedIndex = i
        }
        settingsScope = selected.ownSettings == nil ? .roll : .frame
        if selected.positiveStale { render(selected) }
    }

    /// All frames in the current selection, in strip order.
    var selectedFrames: [Frame] { selection.sorted().map { frames[$0] } }
    /// Selected frames that can go into the queue.
    var selectedToQueue: [Frame] { selectedFrames.filter { $0.phase == .previewed && !$0.skipped } }
    var selectedInQueue: [Frame] { selectedFrames.filter { $0.phase == .queued } }

    /// Scanned frames in the current selection, in strip order.
    var selectedScans: [Frame] {
        selection.sorted().map { frames[$0] }.filter(\.isScanned)
    }

    // MARK: - Export

    func fileStem(_ f: Frame) -> String {
        let slug = rollName.replacingOccurrences(of: " ", with: "")
        return "\(slug)_\(f.name)"
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = folder.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url { folder = url }
    }

    func revealFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }
}
