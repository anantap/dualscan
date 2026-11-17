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
        model.autoEject = false   // strip 1 stays in for the editing checks; strip 2 tests it
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
        // Keys: → → ⇧→ selects 03…04, Q queues them, Q again takes them out.
        model.select(0)
        model.perform(.next(extend: false)); model.perform(.next(extend: false)); model.perform(.next(extend: true))
        let sel = model.selectedFrames.map(\.name).joined(separator: ",")
        model.perform(.toggleQueue)
        let queued = model.queue.map(\.name).joined(separator: ",")
        model.perform(.toggleQueue)
        model.perform(.previous(extend: false))
        log("keys: selected \(sel) · Q queued \(queued) · Q again leaves \(model.queue.count) · ← lands on \(model.selected.name)")
        do {
            func key(_ c: String, _ code: UInt16, _ m: NSEvent.ModifierFlags = []) -> String {
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: m, timestamp: 0, windowNumber: 0, context: nil,
                                         characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
                return KeyCommand.from(e).map { "\($0)" } ?? "passes through"
            }
            log("key map: q→\(key("q", 12)) · ⌘q→\(key("q", 12, .command)) · ⇧→→\(key("", 124, .shift)) · return→\(key("\r", 36)) · ⌘return→\(key("\r", 36, .command)) · x→\(key("x", 7))")
        }
        model.select(0)
        model.perform(.toggleQueue)
        model.select(1)
        model.perform(.toggleQueue)
        shot("3b-queue")
        model.perform(.startQueue)
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
        // Sync: frame 02 gets its own contrast, then 01 + 02 move exposure together.
        let (f1, f2, f3) = (model.frames[0], model.frames[1], model.frames[2])
        model.select(1)
        model.shownEdit.contrast = 60
        model.select(0)
        model.select(1, modifiers: .command)
        model.shownEdit.exposure = 25
        log("sync: 01 exposure \(f1.edit.exposure) contrast \(f1.edit.contrast) · 02 exposure \(f2.edit.exposure) contrast \(f2.edit.contrast) · label \(model.editTargetLabel)")
        model.copyEdit()
        model.select(2)
        model.pasteEdit()
        log("paste on 03: \(f3.edit == f2.edit ? "same as 02" : "DIFFERENT")")
        model.select(0)
        model.select(1, modifiers: .command)
        try? await Task.sleep(for: .seconds(1))
        shot("4b-two-selected")
        let t0 = Date()
        let urls = await model.export(model.selectedScans, ExportOptions(formats: [.jpeg, .baseTIFF, .raw]), reveal: false)
        log(String(format: "export 2 frames × 3 formats: %.2f s", Date().timeIntervalSince(t0)))
        log("exported: \(urls.map(\.lastPathComponent))")
        do {
            // Settings survive a round trip (without touching the real preferences).
            var o = ExportOptions(formats: [.baseTIFF, .raw]); o.size = .edge2000; o.quality = 80
            let back = try? JSONDecoder().decode(ExportOptions.self, from: JSONEncoder().encode(o))
            log("export settings round trip: \(back == o ? "same" : "DIFFERENT")")
            model.select(0)
            model.showExportSheet(wholeRoll: true)
            let sheet = ExportSheet().environment(model)
            let r = ImageRenderer(content: sheet)
            if let img = r.nsImage, let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("5b-export-sheet-roll.png"))
            }
            model.showExport = false
            let t1 = Date()
            let all = await model.export(model.rollScans, ExportOptions(formats: [.jpeg]), reveal: false)
            log(String(format: "export whole roll (%d scans) as JPEG: %d files in %.2f s", model.rollScans.count, all.count, Date().timeIntervalSince(t1)))
        }
        shot("5-exported")
        // Strip 2: eject, the next strip goes in, its frames continue at 07 and its raw files sit
        // next to strip 1's instead of over them. The whole roll then has both strips.
        do {
            let before = model.rollScans.count
            let first = model.frames[0], original = first.full
            model.eject()
            await wait { model.stripNumber == 2 && model.previewedCount == 6 && !model.previewRunning }
            shot("7-strip-2")
            let reread = await first.loadFull()
            log("strip 1 frame 01 read back from its raw file: in memory \(first.full == nil ? "dropped" : "kept"), pixels " +
                (reread.map { r in original.map { r.width == $0.width && r.height == $0.height && r.data == $0.data } ?? false } == true ? "identical" : "DIFFERENT"))
            // Queue the whole strip: when it's done, the strip ejects by itself and strip 3 is next.
            model.autoEject = true
            model.addAllToQueue()
            model.perform(.startQueue)
            await wait { model.stripNumber == 3 }
            log("strip 2 done: ejected by itself → strip \(model.stripNumber), frames " + model.frames.map(\.name).joined(separator: ","))
            let raws = (try? FileManager.default.contentsOfDirectory(atPath: model.rollFolder.appendingPathComponent("Raw").path)) ?? []
            log("raw files " + raws.sorted().joined(separator: ","))
            let all = await model.export(model.rollScans, ExportOptions(formats: [.baseTIFF]), reveal: false)
            log("whole roll after strip 2: \(before) + strip 2 → \(model.rollScans.count) scans, exported \(all.count) base TIFFs: " + all.map(\.lastPathComponent).joined(separator: ","))
        }
        // The update popup, as if build +2 were downloaded.
        Updater.shared.showForSelfTest(.ready(Updater.shared.currentBuild + 2), notes: [
            "Frame numbers continue across strips, so strip 2 no longer overwrites strip 1",
            "Focus once per strip and exposure once per roll",
            "Eject the strip by itself after its last frame",
        ])
        do {
            let r = ImageRenderer(content: UpdatePrompt().environment(model))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("6-update-popup.png"))
            }
        }
        Updater.shared.showForSelfTest(.idle)
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
