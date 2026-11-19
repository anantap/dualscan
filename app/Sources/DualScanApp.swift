import SwiftUI

@main
struct DualScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        Theme.registerFonts()
    }

    var body: some Scene {
        Window(Edition.name, id: "main") {
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
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.check(userInitiated: true) }
            }
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
                Button(AppModel.exportLabel(model.selectedScans.count) + "…") { model.showExportSheet(wholeRoll: false) }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selectedScans.isEmpty || model.exportProgress != nil)
                Button("Export Roll…") { model.showExportSheet(wholeRoll: true) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.rollScans.isEmpty || model.exportProgress != nil)
                Button("Show Scans Folder") { model.revealFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.start()
    }

    /// A downloaded update goes in place when the app quits, so the next start is the new version.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Updater.shared.install(relaunch: false) }
    }
}
