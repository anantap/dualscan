import SwiftUI

struct SidePanel: View {
    @Environment(AppModel.self) private var model

    private enum Kind { case connect, scan, edit }
    private var kind: Kind {
        switch model.mode {
        case .connecting, .insertHolder: return .connect
        case .working: return model.selected.isScanned ? .edit : .scan
        }
    }

    var body: some View {
        ZStack {
            switch kind {
            case .connect: ConnectPanel().transition(.opacity)
            case .scan: ScanPanel().transition(.opacity)
            case .edit: EditPanel().transition(.opacity)
            }
        }
        .animation(Motion.fade, value: kind)
    }
}

/// Cards that scroll, with an optional block of buttons pinned to the bottom.
struct PanelLayout<Cards: View, Actions: View>: View {
    @ViewBuilder var cards: Cards
    @ViewBuilder var actions: Actions
    var body: some View {
        VStack(spacing: 8) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) { cards }
            }
            actions
        }
    }
}

// MARK: - Before the holder is in

struct ConnectPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        PanelLayout {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                HeadCard(title: "Dual Scan", subtitle: subtitle, status: status, busy: model.mode == .connecting,
                         count: elapsed(ctx.date), countSup: model.mode == .connecting ? "elapsed" : "")
            }
            GlassCard(spacing: 16) {
                CardKey(text: "Warm-up")
                VStack(alignment: .leading, spacing: 8) {
                    Dim(text: "Extra time after the scanner is ready")
                    Seg(options: [(0, "None"), (2, "2 min"), (5, "5 min")], selection: $model.extraWarmupMinutes)
                }
                Dim(text: "A longer warm-up keeps colour steadier across the roll.")
            }
            RollCard()
            GlassCard {
                CardKey(text: "Film")
                Seg(options: FilmType.allCases.map { ($0, $0.label) }, selection: $model.film)
            }
        } actions: { EmptyView() }
    }

    private var subtitle: String {
        switch model.connection {
        case .searching: return "Waiting for the scanner"
        case .opening, .warmingUp: return "Warming up"
        case .failed: return "Scanner problem"
        case .ready: return "New roll"
        }
    }

    private var status: [String] {
        switch model.connection {
        case .searching: return ["Not connected", model.useSimulator ? "Starting the simulator" : "Plug in and turn on"]
        case .opening: return [model.scanner?.displayName ?? "Scanner", "Lamp and calibration"]
        case .warmingUp: return [model.scanner?.displayName ?? "Scanner", "Extra warm-up"]
        case .failed: return ["Not connected", "See the message on the left"]
        case .ready: return [model.scanner?.displayName ?? "Scanner", "Ready · insert the holder"]
        }
    }

    private func elapsed(_ now: Date) -> String {
        guard model.mode == .connecting, let s = model.warmupStarted else { return model.mode == .connecting ? "–" : "0" }
        let t = Int(now.timeIntervalSince(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct RollCard: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        GlassCard(spacing: 16) {
            CardKey(text: "Roll")
            VStack(alignment: .leading, spacing: 8) {
                Dim(text: "Name")
                FieldBox(text: $model.rollName)
            }
            Dim(text: "Used in the file names. You choose where to export after scanning.")
        }
    }
}

// MARK: - Unscanned frame: settings and queue

struct ScanPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let f = model.selected
        PanelLayout {
            HeadCard(title: model.rollName, subtitle: subtitle, status: status,
                     busy: model.previewRunning || model.queueRunning,
                     count: model.previewRunning ? "\(model.previewedCount)" : "\(model.queue.count)",
                     countSup: model.previewRunning ? "/6" : "queued")

            if model.previewRunning || !model.frames.contains(where: { $0.phase.filledDots >= 2 }) {
                NextCard()
            }

            if f.skipped {
                GlassCard(spacing: 16) {
                    CardKey(text: "Frame \(f.name)")
                    Text("This frame is skipped. It looked blank, or you chose to skip it.")
                    Button("Don't skip it") { f.skipped = false }.chip(wide: true)
                }
            } else {
                SettingsCard()
            }

            if !model.queue.isEmpty || model.queueRunning { QueueCard() }
        } actions: {
            VStack(spacing: 8) {
                let toAdd = model.selectedToQueue, inQueue = model.selectedInQueue
                if !toAdd.isEmpty {
                    Button(toAdd.count == 1 ? "Add frame \(toAdd[0].name) to queue" : "Add \(toAdd.count) frames to queue") {
                        toAdd.forEach { model.addToQueue($0) }
                    }
                    .chip(wide: true, height: 48)
                    .help("Q")
                } else if !inQueue.isEmpty {
                    Button(inQueue.count == 1 ? "Remove frame \(inQueue[0].name) from queue" : "Remove \(inQueue.count) frames from queue") {
                        inQueue.forEach { model.removeFromQueue($0) }
                    }
                    .chip(wide: true, height: 48)
                    .help("Q")
                }
                if !model.queueRunning {
                    let n = model.queue.count
                    Button(n == 0 ? "Start queue" : "Start queue · \(n) frame\(n == 1 ? "" : "s")") { model.startQueue() }
                        .chip(.primary, wide: true, height: 48)
                        .help("Return")
                        .disabled(n == 0 || model.previewRunning)
                        .opacity(n == 0 || model.previewRunning ? 0.4 : 1)
                }
            }
        }
    }

    private var subtitle: String {
        if model.previewRunning { return "Previewing" }
        if model.queueRunning { return "Queue running" }
        return "Building the queue"
    }

    private var status: [String] {
        let name = model.scanner?.displayName ?? "Scanner"
        if model.previewRunning { return [name, "Reading the strip"] }
        if model.queueRunning, let a = model.activeFrame { return [name, "Scanning frame \(a.name)"] }
        if model.selection.count > 1 { return [name, "\(model.selection.count) frames selected"] }
        return [name, "⇧- or ⌘-click to select more frames"]
    }
}

struct NextCard: View {
    var body: some View {
        GlassCard(spacing: 16) {
            CardKey(text: "Next")
            Text("Check each frame, then add it to the scan queue. You can start building the queue before the preview is done.")
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(Theme.line)
            VStack(alignment: .leading, spacing: 10) {
                Dim(text: "The dots under each frame show how far it is")
                legend("Previewed", 1)
                legend("In the scan queue", 2)
                legend("Scanned, ready to edit", 3)
                legend("Exported", 4)
                HStack {
                    Dim(text: "Light dot: busy now · rings: skipped")
                    Spacer()
                    PhaseDots(filled: 0, busy: 0).mask(alignment: .leading) { Rectangle().frame(width: 8) }
                    PhaseDots(filled: 0, busy: nil, skipped: true).mask(alignment: .leading) { Rectangle().frame(width: 8) }
                }
            }
        }
    }

    private func legend(_ label: String, _ n: Int) -> some View {
        HStack { Text(label); Spacer(); PhaseDots(filled: n, busy: nil) }
    }
}

struct SettingsCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let s = model.shownSettings
        GlassCard(spacing: 16) {
            HStack {
                CardKey(text: "Scan settings")
                Spacer()
                Seg(options: [(AppModel.Scope.roll, "Whole roll"), (.frame, model.selection.count > 1 ? "These frames" : "This frame")],
                    selection: Binding(get: { model.settingsScope }, set: { model.setSettingsScope($0) }), small: true)
                    .frame(width: 176)
            }
            Seg(options: [(800, "800"), (1600, "1600"), (3200, "3200 dpi")], selection: $model.shownSettings.dpi)
            HStack {
                Text("Exposure")
                Spacer()
                Seg(options: [(true, "Auto"), (false, "Manual")], selection: $model.shownSettings.autoExposure, small: true)
                    .frame(width: 176)
            }
            if !s.autoExposure {
                VStack(spacing: 8) {
                    exposureBar("Red", \.r)
                    exposureBar("Green", \.g)
                    exposureBar("Blue", \.b)
                }
            }
            SettingRow(title: "Autofocus", detail: "A few seconds per frame", isOn: $model.shownSettings.autofocus)
            SettingRow(title: "Multi-sample", detail: "Less noise, about 3× slower", isOn: $model.shownSettings.multiSample)
        }
    }

    private func exposureBar(_ label: String, _ kp: WritableKeyPath<RGBExposure, Int>) -> some View {
        @Bindable var model = model
        return BarSlider(label: label,
                         value: Binding(get: { Double(model.shownSettings.exposure[keyPath: kp]) },
                                        set: { model.shownSettings.exposure[keyPath: kp] = Int($0) }),
                         range: 54...2033, defaultValue: 100, format: { String(Int($0)) }, step: 1)
    }
}

struct QueueCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let items = model.frames.filter { $0.phase == .queued || $0.phase == .scanning }
        GlassCard {
            HStack {
                CardKey(text: "Scan queue")
                Spacer()
                if !model.queue.isEmpty {
                    Button("Clear") { model.clearQueue() }.chip(height: 28, small: true)
                }
            }
            ForEach(items) { f in
                HStack(spacing: 12) {
                    if let img = f.negativeThumb {
                        Image(decorative: img, scale: 1).resizable().scaledToFill()
                            .frame(width: 48, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Frame \(f.name)")
                        Dim(text: f.phase == .scanning ? "Scanning · \(Int(f.progress * 100))%" : model.settings(for: f).summary)
                    }
                    Spacer()
                    if f.phase == .queued {
                        Button { model.removeFromQueue(f) } label: { Image(systemName: "xmark") }
                            .chip(height: 32, small: true)
                            .accessibilityLabel("Remove frame \(f.name) from the queue")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(f.phase == .scanning ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1.5))
                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
        }
        .animation(Motion.slide, value: items.map(\.id))
        .animation(Motion.fade, value: items.map { $0.phase == .scanning })
    }
}

// MARK: - Scanned frame: base edit

struct EditPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showApps = false

    var body: some View {
        @Bindable var model = model
        PanelLayout {
            HeadCard(title: model.rollName, subtitle: "\(model.editTargetLabel) · base edit", status: status, busy: model.queueRunning,
                     count: "\(model.scannedCount)", countSup: "scanned")

            GlassCard(spacing: 16) {
                HStack {
                    CardKey(text: "Conversion")
                    Spacer()
                    Dim(text: "Whole roll")
                }
                Seg(options: FilmType.allCases.map { ($0, $0.label) }, selection: $model.film)
                if model.film != .slide {
                    FilmBaseRow(baseColor: baseColor)
                }
            }

            GlassCard {
                HStack {
                    CardKey(text: "Levels")
                    Spacer()
                    Dim(text: model.editTargetLabel)
                }
                BarSlider(label: "Exposure", value: $model.shownEdit.exposure, range: -100...100)
                BarSlider(label: "Contrast", value: $model.shownEdit.contrast, range: 0...100, defaultValue: 30, format: { String(Int($0)) })
                BarSlider(label: "Black point", value: $model.shownEdit.black, range: -50...50)
                BarSlider(label: "White point", value: $model.shownEdit.white, range: -50...50)
            }

            GlassCard {
                HStack {
                    CardKey(text: "Color")
                    Spacer()
                    Button { model.picking = model.picking == .neutral ? nil : .neutral } label: {
                        Label("Pick grey", systemImage: "eyedropper")
                    }
                    .chip(model.picking == .neutral ? .on : .normal, height: 28, small: true)
                    .help("Click something that should be grey or white")
                }
                BarSlider(label: "Temperature", value: $model.shownEdit.temp, range: -100...100)
                BarSlider(label: "Tint", value: $model.shownEdit.tint, range: -100...100)
                BarSlider(label: "Saturation", value: $model.shownEdit.saturation, range: 0...200, defaultValue: 100, format: { String(Int($0)) })
                HStack {
                    Button("Reset") { model.shownEdit = EditSettings() }
                        .buttonStyle(.plain).font(.s).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button("Copy to all frames") { model.copyEditToAll() }
                        .buttonStyle(.plain).font(.s).foregroundStyle(Theme.accentText)
                }
                .padding(.top, 4)
            }
        } actions: {
            VStack(spacing: 8) {
                Button(model.openLabel) { showApps = true }
                    .chip(wide: true, height: 48)
                    .popover(isPresented: $showApps, arrowEdge: .leading) { AppPicker(close: { showApps = false }) }
                Button(model.exportLabel) { model.showExportSheet(wholeRoll: false) }
                    .chip(.primary, wide: true, height: 48)
                    .disabled(model.exportProgress != nil)
            }
        }
    }

    private var status: [String] {
        let name = model.scanner?.displayName ?? "Scanner"
        if model.queueRunning, let a = model.activeFrame { return [name, "Scanning frame \(a.name) · \(Int(a.progress * 100))%"] }
        let sel = model.selectedScans.count
        return [name, sel > 1 ? "\(sel) frames selected" : "⌘-click frames to select more"]
    }

    private var baseColor: Color {
        guard let b = model.filmBase else { return Theme.surface2 }
        let c = b.map { pow(pow(10, -$0) / pow(10, -b.min()!), 1 / 2.2) }
        return Color(red: c[0], green: c[1], blue: c[2])
    }
}

struct AppPicker: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(OpenTarget.installed) { t in
                Button {
                    close()
                    let frames = model.selectedScans
                    Task { await model.open(frames, in: t) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(t.name)
                        Dim(text: t.wantsRaw ? "Gets the raw scan" : "Gets a 16-bit TIFF of the base edit")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button {
                close()
                let frames = model.selectedScans
                Task { await model.openWithOtherApp(frames) }
            } label: {
                Text("Other app…").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.m)
        .padding(8)
        .frame(width: 280)
    }
}


/// The roll's film base: measured, picked by hand, or a saved film stock.
struct FilmBaseRow: View {
    @Environment(AppModel.self) private var model
    let baseColor: Color
    @State private var naming = false
    @State private var stockName = ""

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8).fill(baseColor)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.15)))
                .frame(width: 32, height: 32)
            Menu {
                Button("Measure from the roll") { model.resetBase() }
                if !model.savedStocks.isEmpty {
                    Section("Saved film stocks") {
                        ForEach(model.savedStocks.keys.sorted(), id: \.self) { name in
                            Button(name) { model.useStock(name) }
                        }
                    }
                }
                Divider()
                Button("Save as film stock…") { stockName = currentStockName; naming = true }
                    .disabled(model.filmBase == nil)
                if case .stock(let name) = model.baseSource {
                    Button("Forget \(name)") { model.deleteStock(name) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("Film base")
                        Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    }
                    Dim(text: sourceText)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Button { model.picking = model.picking == .base ? nil : .base } label: { Image(systemName: "eyedropper") }
                .chip(model.picking == .base ? .on : .normal, height: 32, small: true)
                .help("Pick bare film in the image").accessibilityLabel("Pick the film base in the image")
        }
        .alert("Save film stock", isPresented: $naming) {
            TextField("Film stock, e.g. Portra 400", text: $stockName)
            Button("Save") { model.saveStock(stockName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The film base of this roll is remembered under this name, for later rolls of the same film.")
        }
    }

    private var currentStockName: String {
        if case .stock(let n) = model.baseSource { return n }
        return ""
    }

    private var sourceText: String {
        switch model.baseSource {
        case .measured: return "Measured from the roll"
        case .picked: return "Picked by you"
        case .stock(let n): return n
        }
    }
}
