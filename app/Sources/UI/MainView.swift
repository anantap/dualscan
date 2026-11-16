import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            // The strip sits in the same column as the stage, so it is exactly as wide.
            VStack(spacing: 8) {
                StageView()
                StripView()
            }
            SidePanel()
                .frame(width: 344)
        }
        .padding(8)
        .background(MistBackground())
        .font(.m)
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .alert("Dual Scan", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }
}

/// Which big state the window is in.
enum Mode { case connecting, insertHolder, working }

extension AppModel {
    var mode: Mode {
        if connection != .ready { return .connecting }
        return holderIn || hasPreviews ? .working : .insertHolder
    }
}

// MARK: - Strip

struct StripView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(model.frames.enumerated()), id: \.element.id) { i, f in
                FrameThumb(frame: f, active: model.selection.contains(i) && model.mode == .working)
                    .onTapGesture {
                        let flags = NSEvent.modifierFlags
                        var mods: EventModifiers = []
                        if flags.contains(.command) { mods.insert(.command) }
                        if flags.contains(.shift) { mods.insert(.shift) }
                        model.select(i, modifiers: mods)
                    }
                    .contextMenu {
                        Button(f.skipped ? "Don't skip this frame" : "Skip this frame") {
                            f.skipped.toggle()
                            if f.skipped { model.removeFromQueue(f) }
                        }
                        .disabled(f.phase == .scanning)
                    }
            }
        }
    }
}

struct FrameThumb: View {
    let frame: Frame
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let img = frame.isScanned ? (frame.positiveThumb ?? frame.negativeThumb) : frame.negativeThumb {
                    Image(decorative: img, scale: 1).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(frame.skipped ? 0.35 : 1)

            HStack {
                Text(frame.name).font(.pixel(12)).foregroundStyle(active ? Theme.accentText : Theme.textDim)
                Spacer()
                PhaseDots(filled: frame.phase.filledDots, busy: frame.phase.busyDot, skipped: frame.skipped)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(frame.preview == nil ? .white.opacity(0.04) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(active ? Theme.accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Frame \(frame.name), \(frame.skipped ? "skipped" : frame.phase.label)")
        .accessibilityAddTraits(.isButton)
    }
}
