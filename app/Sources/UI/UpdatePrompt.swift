import SwiftUI

/// The popup when a newer build is downloaded: what it fixes, then restart now, later
/// (it goes in place when you quit) or skip this build. No restart while the scanner or an
/// export is busy.
struct UpdatePrompt: View {
    @Environment(AppModel.self) private var model
    private var updater: Updater { .shared }

    private var build: Int {
        if case .ready(let b) = updater.state { return b }
        return updater.currentBuild
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Update").font(.s).foregroundStyle(Theme.accentText)
                Text("Build \(build) is ready").font(.l)
                Dim(text: "You have build \(updater.currentBuild).")
            }

            if !updater.notes.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    CardKey(text: "What's new")
                    // A long list scrolls; a short one (the usual) just shows.
                    if updater.notes.count > 8 {
                        ScrollView(showsIndicators: false) { list }.frame(height: 220)
                    } else {
                        list
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface2))
            }

            if let problem = updater.installProblem {
                Dim(text: problem)
            } else if model.isBusy {
                Dim(text: "Restart once the scanner is done, or it goes in place when you quit.")
            }

            HStack(spacing: 8) {
                Button("Skip this build") { updater.skip() }.chip()
                Spacer(minLength: 0)
                Button("Later") { updater.later() }.chip()
                if updater.installProblem == nil {
                    Button("Restart now") { updater.restartNow() }
                        .chip(.primary)
                        .disabled(model.isBusy)
                        .opacity(model.isBusy ? 0.4 : 1)
                }
            }
        }
        .padding(32)
        .frame(width: 480)
        .background(Theme.surround)
        .foregroundStyle(Theme.text)
        .font(.m)
        .preferredColorScheme(.dark)
    }
}

extension UpdatePrompt {
    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(updater.notes, id: \.self) { note in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text(note).font(.s).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AppModel {
    /// Scanning or exporting: no restart now.
    var isBusy: Bool { queueRunning || previewRunning || exportProgress != nil }
}
