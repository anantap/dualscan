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
    let frames: [Frame] = (1...6).map { Frame(number: $0) }
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
    var message: String?

    private var renderTasks: [Int: Task<Void, Never>] = [:]

    init() {
        let saved = UserDefaults.standard.object(forKey: "extraWarmup") as? Int
        extraWarmupMinutes = saved ?? 2
    }

    // MARK: - Derived

    var queue: [Frame] { frames.filter { $0.phase == .queued } }
    var scannedCount: Int { frames.filter(\.isScanned).count }
    var previewedCount: Int { frames.filter { $0.phase != .empty && $0.phase != .previewing }.count }
    var hasPreviews: Bool { frames.contains { $0.preview != nil } }

    func settings(for f: Frame) -> ScanSettings { f.ownSettings ?? rollSettings }
    func edit(for f: Frame) -> EditSettings { f.edit }

    /// Binding target for the scan settings card.
    var shownSettings: ScanSettings {
        get { settingsScope == .frame ? (selected.ownSettings ?? rollSettings) : rollSettings }
        set {
            if settingsScope == .frame { selected.ownSettings = newValue } else { rollSettings = newValue }
        }
    }

    /// Binding target for the edit cards.
    var shownEdit: EditSettings {
        get { selected.edit }
        set { selected.edit = newValue; render(selected) }
    }

    /// Gives every other scanned frame the selected frame's base edit.
    func copyEditToAll() {
        for f in frames where f !== selected && f.editSource != nil { f.edit = selected.edit; render(f, delay: 0.1) }
    }

    // MARK: - Connecting

    func start() {
        SaneSession.configure()
        if CommandLine.arguments.contains("--simulate") || CommandLine.arguments.contains("--selftest") {
            useSimulator = true
            extraWarmupMinutes = 0
        }
        Task { await connect() }
    }

    func useSimulatedScanner() {
        useSimulator = true
        if case .searching = connection { } else { return }
    }

    private func connect() async {
        connection = .searching
        var device: ScannerDevice?
        while device == nil {
            if useSimulator {
                device = SimulatedScanner(film: film)
                break
            }
            let found: (name: String, model: String)? = await withCheckedContinuation { c in
                SaneSession.queue.async { c.resume(returning: SaneSession.findDualIV()) }
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
            for f in frames where !f.isScanned { f.reset() }
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
                let result = try await scanner.scan(ScanRequest(frame: f.number, settings: rollSettings, preview: true)) { p in
                    Task { @MainActor in f.progress = p }
                }
                f.preview = result.image
                f.lastExposure = result.exposure
                f.phase = .previewed
                await prepare(f, from: result.image)
                if isBlank(result.image) { f.skipped = true }
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
    private func isBlank(_ img: Image16) -> Bool {
        let h = Converter.histogram(img)
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
        Task { await runQueue() }
    }

    func pauseQueue() { pauseRequested = true }

    private func runQueue() async {
        guard let scanner else { return }
        queueRunning = true
        pauseRequested = false
        defer { queueRunning = false; activeFrame = nil; pauseRequested = false }
        // Frames added while the queue runs are picked up too.
        while !pauseRequested, let f = frames.first(where: { $0.phase == .queued }) {
            f.phase = .scanning
            f.progress = 0
            activeFrame = f
            do {
                let result = try await scanner.scan(ScanRequest(frame: f.number, settings: settings(for: f), preview: false)) { p in
                    Task { @MainActor in f.progress = p }
                }
                f.full = result.image
                f.lastExposure = result.exposure
                f.lastFocus = result.focus
                await saveRaw(f, result.image)
                f.proxy = await Task.detached { result.image.downscaled(maxEdge: 1800) }.value
                await prepare(f, from: f.proxy!)
                f.phase = .scanned
            } catch ScannerError.cancelled {
                f.phase = .queued
                return
            } catch {
                f.phase = .queued
                f.error = error.localizedDescription
                message = error.localizedDescription
                return
            }
        }
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

    /// Histogram, negative image and first positive for a fresh scan or preview.
    private func prepare(_ f: Frame, from img: Image16) async {
        let (hist, neg) = await Task.detached { (Converter.histogram(img), img.negativeCGImage()) }.value
        f.histogram = hist
        f.negativeImage = neg
        estimateFilmBase()
        rerenderAll()
    }

    /// The thinnest density over all frames: the film base. Blank frames
    /// (unexposed film) count too, and are the best sample there is.
    private func estimateFilmBase() {
        guard baseSource == .measured else { return }
        let bases = frames.compactMap { f in f.editSource.flatMap { Converter.estimateBase($0) } }
        guard !bases.isEmpty else { return }
        filmBase = (0..<3).map { c in bases.map { $0[c] }.min()! }
    }

    /// Handles a click on the image while picking; `point` is 0...1 in the shown image.
    func pick(atUnit point: CGPoint) {
        guard let mode = picking, let img = selected.editSource else { return }
        let rotated = img.rotated(selected.rotation)
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
            shownEdit = e
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

    func analysis(for f: Frame) -> Converter.Analysis {
        // The conversion is shared by the whole roll.
        let hist: Converter.Histogram?
        do {
            let scanned = frames.filter { $0.isScanned }.compactMap(\.histogram)
            let pool = scanned.isEmpty ? frames.filter { !$0.skipped }.compactMap(\.histogram) : scanned
            hist = pool.isEmpty ? nil : Converter.Histogram.merged(pool)
        }
        return Converter.analyze(hist, base: filmBase)
    }

    /// The selected frame updates right away; the others (thumbnails) once
    /// the slider has been still for a moment.
    func rerenderAll() {
        for f in frames where f.editSource != nil {
            render(f, delay: f === selected ? 0 : 0.4)
        }
    }

    func render(_ f: Frame, delay: Double = 0) {
        guard f.editSource != nil else { return }
        renderTasks[f.number]?.cancel()
        renderTasks[f.number] = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
            }
            guard let src = f.editSource else { return }
            let params = Converter.params(analysis(for: f), edit(for: f), film: film)
            let rotation = f.rotation
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                let r = src.rotated(rotation)
                return CGImage.rgba8(Converter.render8(r, params), width: r.width, height: r.height)
            }.value
            if !Task.isCancelled { f.positiveImage = image }
        }
    }

    func rotateSelected() {
        selected.rotation = (selected.rotation + 270) % 360
        let f = selected
        if let n = f.negativeImage, f.editSource != nil {
            _ = n
            Task {
                let src = f.editSource!
                let rot = f.rotation
                f.negativeImage = await Task.detached { src.rotated(rot).negativeCGImage() }.value
            }
        }
        render(f)
    }

    func setSettingsScope(_ s: Scope) {
        settingsScope = s
        if s == .frame, selected.ownSettings == nil { selected.ownSettings = rollSettings }
        if s == .roll { selected.ownSettings = nil }
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
    }

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
