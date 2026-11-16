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
        model.select(4, modifiers: .shift)
        log("shift-select 03…05 → can add: " + model.selectedToQueue.map(\.name).joined(separator: ","))
        shot("3-shift-selected")
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
        await measureSlider(model, roll: false)
        await measureSlider(model, roll: true)
        do {
            let f = model.selected
            func sizes() -> String {
                [f.positiveImage, f.positiveThumb, f.negativeImage, f.negativeThumb]
                    .map { $0.map { "\($0.width)×\($0.height)" } ?? "-" }.joined(separator: " ")
            }
            model.rotateSelected()
            await wait({ f.positiveImage.map { $0.height > $0.width } ?? false }, 5)
            try? await Task.sleep(for: .milliseconds(200))
            log("rotated left: " + sizes())
            for _ in 0..<3 { model.rotateSelected() }
            await wait({ f.positiveImage.map { $0.width > $0.height } ?? false }, 5)
            try? await Task.sleep(for: .milliseconds(200))
            log("rotated back: " + sizes())
        }
        model.select(1, modifiers: .command)
        try? await Task.sleep(for: .seconds(1))
        shot("4b-two-selected")
        let urls = await model.export(model.selectedScans, ExportOptions(formats: [.jpeg, .baseTIFF, .raw]), reveal: false)
        log("exported: \(urls.map(\.lastPathComponent))")
        shot("5-exported")
        log("frames: " + model.frames.map { "\($0.name)=\($0.phase)\($0.skipped ? "/skip" : "")" }.joined(separator: " "))
        NSApp.terminate(nil)
    }

    /// Drags a slider for two seconds at 120 Hz and logs how the app keeps up:
    /// the worst main-thread stall, how often the big image changed, and how
    /// long the last change took to show. `roll` moves a roll-wide setting
    /// (all frames redraw) instead of the frame's own exposure.
    static func measureSlider(_ model: AppModel, roll: Bool) async {
        let f = model.selected
        var stall = 0.0, setCost = 0.0, updates = 0
        var last = f.positiveImage
        let ticks = 240
        for i in 0..<ticks {
            let t0 = Date()
            if roll {
                model.filmBase = model.filmBase.map { b in b.map { $0 + (i % 2 == 0 ? 0.001 : -0.001) } }
                model.rerenderAll()
            } else {
                var e = model.shownEdit
                e.exposure = Double(i % 100) - 50
                model.shownEdit = e
            }
            setCost = max(setCost, Date().timeIntervalSince(t0))
            let t1 = Date()
            try? await Task.sleep(for: .milliseconds(8))
            stall = max(stall, Date().timeIntervalSince(t1) - 0.008)
            if f.positiveImage !== last { updates += 1; last = f.positiveImage }
        }
        // How long until the image for the last value is on screen.
        let t2 = Date()
        while f.shownRender < f.requestedRender, Date().timeIntervalSince(t2) < 2 { try? await Task.sleep(for: .milliseconds(1)) }
        let settle = Date().timeIntervalSince(t2)
        let size = f.positiveImage.map { "\($0.width)×\($0.height)" } ?? "-"
        log(String(format: "slider %@: worst stall %.1f ms, worst set %.1f ms, %d image updates in %d ticks, last shown after %.1f ms, image %@",
                   roll ? "roll-wide" : "frame", stall * 1000, setCost * 1000, updates, ticks, settle * 1000, size))
    }

    static func log(_ s: String) {
        guard let dir = outputDir else { return }
        let url = dir.appendingPathComponent("log.txt")
        let line = Data((s + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
}
