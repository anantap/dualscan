import SwiftUI

@main
struct DualScanApp: App {
    @State private var model = AppModel()

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        Window("Dual Scan", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 720)
                .task {
                    model.start()
                    if let dir = SelfTest.outputDir { await SelfTest.run(model, to: dir) }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Copy Edit") { model.copyEdit() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selected.display == nil)
                Button(model.editTargets.count > 1 ? "Paste Edit to \(model.editTargets.count) Frames" : "Paste Edit") { model.pasteEdit() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.copiedEdit == nil || model.editTargets.isEmpty)
            }
            CommandGroup(after: .newItem) {
                Button("Show Scans Folder") { model.revealFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
