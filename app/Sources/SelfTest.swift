import SwiftUI

/// `--selftest <dir>`: runs the whole flow on the simulated scanner, saves a
/// picture of the window at each step and the exported files, then quits.
@MainActor
enum SelfTest {
    static var outputDir: URL? {
        guard let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    }

    static func run(_ model: AppModel, to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        model.libraryRoot = dir.appendingPathComponent("Library")
        model.folder = dir.appendingPathComponent("Export")
        func shot(_ name: String) {
            let view = MainView().environment(model).frame(width: 1440, height: 900)
            let r = ImageRenderer(content: view)
            r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
            }
            log("shot \(name): mode=\(model.mode) connection=\(model.connection)")
        }
        func wait(_ cond: () -> Bool, _ limit: Double = 120) async {
            let end = Date().addingTimeInterval(limit)
            while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(200)) }
        }

        try? await Task.sleep(for: .milliseconds(500))
        shot("0-connect")
        await wait { model.previewRunning }
        try? await Task.sleep(for: .seconds(2.5))
        shot("2-previewing")
        await wait { !model.previewRunning && model.previewedCount == 6 }
        model.select(2)
        shot("3-preview-done")
        model.addToQueue(model.frames[0])
        model.addToQueue(model.frames[1])
        shot("3b-queue")
        model.startQueue()
        await wait { model.frames[0].isScanned }
        model.addAllToQueue()
        model.select(0)
        try? await Task.sleep(for: .seconds(1))
        shot("4-editing-while-scanning")
        await wait { !model.queueRunning && model.queue.isEmpty }
        model.select(0)
        model.select(1, modifiers: .command)
        try? await Task.sleep(for: .seconds(1))
        shot("4b-two-selected")
        let urls = await model.export(model.selectedScans, ExportOptions(), reveal: false)
        log("exported: \(urls.map(\.lastPathComponent))")
        shot("5-exported")
        log("frames: " + model.frames.map { "\($0.name)=\($0.phase)\($0.skipped ? "/skip" : "")" }.joined(separator: " "))
        NSApp.terminate(nil)
    }

    static func log(_ s: String) {
        guard let dir = outputDir else { return }
        let url = dir.appendingPathComponent("log.txt")
        let line = Data((s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
}
