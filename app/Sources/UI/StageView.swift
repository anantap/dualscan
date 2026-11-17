import SwiftUI

struct StageView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            switch model.mode {
            case .connecting: ConnectSteps()
            case .insertHolder: InsertHolder()
            case .working: FrameStage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Theme.surround))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Connect and warm up

struct ConnectSteps: View {
    @Environment(AppModel.self) private var model
    @Namespace private var highlight

    enum StepState { case done, now, todo }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    step(1, "Plug in the scanner and turn it on", detail: plugDetail, state: plugState)
                    step(2, "Warming up the lamp", detail: "Keep the film holder out for now", state: warmState,
                         trailing: warmTrailing(ctx.date))
                    step(3, "Calibrate", detail: "Needs an empty scanner", state: calState)
                    step(4, "Insert the film strip holder", detail: "The preview starts by itself", state: .todo)
                }
                .frame(width: 560)
                .animation(Motion.slide, value: model.connection)
                if case .failed(let msg) = model.connection {
                    VStack(spacing: 12) {
                        Text(msg).foregroundStyle(Theme.accentText).multilineTextAlignment(.center)
                        Button("Try again") { model.retryConnection() }.chip()
                    }
                }
                if case .warmingUp = model.connection {
                    Button("Skip the extra warm-up") { model.skipWarmup() }.chip()
                }
                if model.connection == .searching && !model.useSimulator {
                    Button("No scanner here? Use a simulated one") { model.useSimulator = true }.chip()
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var plugState: StepState { model.connection == .searching ? .now : .done }
    private var plugDetail: String {
        model.connection == .searching ? "Looking for a Dimage Scan Dual IV on USB" : "\(model.scanner?.displayName ?? "Scanner") is answering"
    }
    private var warmState: StepState {
        switch model.connection {
        case .searching: return .todo
        case .opening, .warmingUp: return .now
        default: return .done
        }
    }
    // The driver calibrates while it opens the scanner, and again when a holder goes in.
    private var calState: StepState {
        switch model.connection {
        case .searching, .opening: return .todo
        default: return .done
        }
    }

    private func warmTrailing(_ now: Date) -> String? {
        switch model.connection {
        case .opening:
            return clock(now.timeIntervalSince(model.warmupStarted ?? now))
        case .warmingUp(let until):
            return clock(until.timeIntervalSince(now)) + " left"
        default: return nil
        }
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func step(_ n: Int, _ title: String, detail: String, state: StepState, trailing: String? = nil) -> some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(state == .done ? Theme.ok.opacity(0.18) : state == .now ? Theme.accent : .white.opacity(0.08))
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ok)
                } else {
                    Text("\(n)").font(.pixel(14)).foregroundStyle(state == .now ? .white : Theme.textDim)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                Dim(text: detail)
            }
            Spacer()
            if let trailing { Text(trailing).font(.pixel(24)) }
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white.opacity(0.04))
                // One highlight that slides to the step that's happening now.
                if state == .now {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                        .strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1.5)
                        .matchedGeometryEffect(id: "now", in: highlight)
                }
            }
        }
        .opacity(state == .todo ? 0.55 : 1)
    }
}

struct InsertHolder: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            Image(systemName: "film").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Theme.accentText)
            VStack(spacing: 8) {
                Text("Insert the film strip holder").font(.l)
                Text("The app previews the whole strip as soon as the holder is in.").foregroundStyle(Theme.textDim)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Working

struct FrameStage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let f = model.selected
        VStack(spacing: 0) {
            Toolbar()
                .padding([.horizontal, .top], 16)
            ZStack {
                FrameImage(frame: f)
                    .padding(EdgeInsets(top: 16, leading: 24, bottom: 72, trailing: 24))
                VStack {
                    if f.isScanned, !model.showBefore {
                        Text("Live · no rescan needed").font(.s)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.accent)).foregroundStyle(.white)
                            .padding(.top, 8)
                    }
                    Spacer()
                    HintPill(frame: f)
                        .padding(.bottom, 24)
                }
            }
        }
    }
}

struct Toolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let f = model.selected
        HStack(spacing: 8) {
            if model.previewRunning, let a = model.activeFrame {
                ProgressPill(text: "Previewing frame \(a.number) of 6", progress: a.progress) {
                    Button("Stop") { model.stopPreview() }.chip(height: 28, small: true)
                }
            } else if model.queueRunning, let a = model.activeFrame {
                // A frame that is still being saved counts as done: the scanner is past it.
                let done = model.frames.filter { $0.isScanned || ($0.phase == .scanning && $0 !== a) }.count
                let total = done + model.queue.count + 1
                ProgressPill(text: "Queue · frame \(a.name) · \(done + 1) of \(total)", progress: a.progress) {
                    Button(model.pauseRequested ? "Pausing…" : "Pause") { model.pauseQueue() }
                        .chip(height: 28, small: true).disabled(model.pauseRequested)
                }
            } else {
                Label(model.stripNumber > 1 ? "Film strip \(model.stripNumber) · frames \(model.frames[0].name)–\(model.frames[5].name)" : "Film strip · 6 frames", systemImage: "film").labelStyle(.titleAndIcon)
                    .font(.m).padding(.horizontal, 16).frame(height: 40)
                    .background(Capsule().fill(Theme.surface2))
                Button { model.eject() } label: { Image(systemName: "eject") }
                    .chip().help("Eject the film holder (E)")
                    .accessibilityLabel("Eject film holder")
            }
            Spacer()
            if f.isScanned {
                Button { model.showBefore.toggle() } label: { Label("Before / after", systemImage: "rectangle.split.2x1") }
                    .chip(model.showBefore ? .on : .normal)
                    .help("Show the negative (B)")
                Button { model.rotateSelected() } label: { Image(systemName: "rotate.left") }
                    .chip().help("Rotate left (R)").accessibilityLabel("Rotate left")
            } else if f.preview != nil {
                Button("Show as positive") { model.showPositivePreview.toggle() }
                    .chip(model.showPositivePreview ? .on : .normal)
                Button("Add all to queue") { model.addAllToQueue() }.chip()
                    .disabled(!model.frames.contains { $0.phase == .previewed && !$0.skipped })
            }
        }
    }
}

struct FrameImage: View {
    @Environment(AppModel.self) private var model
    let frame: Frame

    var body: some View {
        GeometryReader { g in
            if let img = shown {
                let size = fitted(CGSize(width: img.width, height: img.height), in: g.size)
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.45), radius: 30, y: 20)
                    .onTapGesture { p in
                        if model.picking != nil {
                            model.pick(atUnit: CGPoint(x: p.x / size.width, y: p.y / size.height))
                        }
                    }
                    .onContinuousHover { phase in
                        if model.picking != nil, case .active = phase { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    if frame.phase == .previewing {
                        ProgressView().controlSize(.small)
                        Text("Previewing frame \(frame.name)…").foregroundStyle(Theme.textDim)
                    } else {
                        Text("Not previewed yet").foregroundStyle(Theme.textDim)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var shown: CGImage? {
        // Until the stage-size render lands, the thumbnail stands in.
        let positive = frame.positiveImage ?? frame.positiveThumb ?? frame.negativeImage
        if frame.isScanned { return model.showBefore ? frame.negativeImage : positive }
        if model.showPositivePreview { return positive }
        return frame.negativeImage
    }

    private func fitted(_ s: CGSize, in box: CGSize) -> CGSize {
        let k = min(box.width / s.width, box.height / s.height)
        return CGSize(width: s.width * k, height: s.height * k)
    }
}

struct HintPill: View {
    @Environment(AppModel.self) private var model
    let frame: Frame

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("Frame")
                Text(frame.name).foregroundStyle(Theme.accentText)
                Text("· \(frame.skipped ? "skipped" : frame.phase.label.lowercased())")
            }
            if let detail { Text(detail).font(.pixel(14)).foregroundStyle(Theme.textDim) }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Capsule().fill(Color(red: 30 / 255, green: 29 / 255, blue: 27 / 255).opacity(0.9)))
    }

    private var detail: String? {
        if model.picking == .base { return "Click bare, unexposed film" }
        if model.picking == .neutral { return "Click something that should be grey or white" }
        if frame.isScanned {
            let s = model.settings(for: frame)
            return "\(s.dpi) dpi · 16-bit" + (frame.lastFocus.map { " · focus \($0)" } ?? "")
        }
        if let e = frame.lastExposure { return "R \(e.r) · G \(e.g) · B \(e.b)" }
        return nil
    }
}
