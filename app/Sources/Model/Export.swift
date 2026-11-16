import Foundation
import AppKit

struct ExportOptions: Equatable {
    enum Format: Hashable { case jpeg, baseTIFF, raw }
    enum Size: Hashable {
        case full, edge3000, edge2000
        var maxEdge: Int? { switch self { case .full: return nil; case .edge3000: return 3000; case .edge2000: return 2000 } }
    }

    /// Which files to write; several can be chosen.
    var formats: Set<Format> = [.jpeg]
    var size: Size = .full
    var quality = 92.0

    init(formats: Set<Format> = [.jpeg]) { self.formats = formats }
}

/// Apps that can take the scans.
struct OpenTarget: Identifiable, Hashable {
    let name: String
    let bundleID: String
    /// The Negatief Converter does its own conversion, so it gets the raw scan.
    var wantsRaw = false
    var id: String { bundleID }

    static let known: [OpenTarget] = [
        OpenTarget(name: "Photoshop", bundleID: "com.adobe.Photoshop"),
        OpenTarget(name: "Compositor", bundleID: "com.wonderassembly.compositor"),
        OpenTarget(name: "Negatief Converter", bundleID: "nl.ananta.negatiefconverter", wantsRaw: true),
    ]

    static var installed: [OpenTarget] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

extension AppModel {
    /// "Export scan" / "Export 2 scans"
    var exportLabel: String {
        let n = selectedScans.count
        return n <= 1 ? "Export scan" : "Export \(n) scans"
    }

    /// "Open in…" / "Open 2 in…"
    var openLabel: String {
        let n = selectedScans.count
        return n <= 1 ? "Open in…" : "Open \(n) in…"
    }

    /// Expected bytes on disk for these frames. TIFFs are uncompressed, so
    /// those are exact; JPEG is estimated by compressing the editing copy.
    func estimatedBytes(_ frames: [Frame], _ o: ExportOptions) async -> Int {
        var total = 0
        for f in frames {
            guard let full = f.full else { continue }
            let tiff = full.width * full.height * 6 + 1024
            if o.formats.contains(.raw) { total += tiff }
            if o.formats.contains(.baseTIFF) { total += tiff }
            if o.formats.contains(.jpeg), let proxy = f.proxy {
                let params = Converter.params(analysis(for: f), edit(for: f), film: film)
                let edge = Double(o.size.maxEdge ?? max(full.width, full.height))
                let scale = min(1, edge / Double(max(full.width, full.height)))
                let target = Double(full.width * full.height) * scale * scale
                let q = o.quality / 100
                let sample: Int = await Task.detached {
                    ImageFiles.jpegData(Converter.render8(proxy, params), width: proxy.width, height: proxy.height, quality: q)?.count ?? 0
                }.value
                total += Int(Double(sample) * target / Double(proxy.width * proxy.height))
            }
        }
        return total
    }

    /// Writes the chosen files for each frame and returns all of them.
    @discardableResult
    func export(_ frames: [Frame], _ o: ExportOptions, reveal: Bool = true) async -> [URL] {
        var written: [URL] = []
        for f in frames {
            guard let full = f.full else { continue }
            let params = Converter.params(analysis(for: f), edit(for: f), film: film)
            let stem = fileStem(f)
            let folder = self.folder
            let rotation = f.rotation
            let rawURL = f.rawURL
            do {
                let urls: [URL] = try await Task.detached(priority: .userInitiated) {
                    var out: [URL] = []
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    if o.formats.contains(.raw) {
                        let u = folder.appendingPathComponent("\(stem)_raw.tif")
                        if let rawURL, rawURL.standardizedFileURL == u.standardizedFileURL {
                            out.append(rawURL)
                        } else if let rawURL {
                            // Copy the kept raw scan to the export folder.
                            try? FileManager.default.removeItem(at: u)
                            try FileManager.default.copyItem(at: rawURL, to: u)
                            out.append(u)
                        } else {
                            try ImageFiles.writeTIFF16(full.data, width: full.width, height: full.height, to: u, linear: true)
                            out.append(u)
                        }
                    }
                    if o.formats.contains(.baseTIFF) || o.formats.contains(.jpeg) {
                        let rotated = full.rotated(rotation)
                        if o.formats.contains(.baseTIFF) {
                            let u = folder.appendingPathComponent("\(stem).tif")
                            try ImageFiles.writeTIFF16(Converter.render16(rotated, params), width: rotated.width,
                                                       height: rotated.height, to: u, linear: false)
                            out.append(u)
                        }
                        if o.formats.contains(.jpeg) {
                            let sized = o.size.maxEdge.map { rotated.downscaled(maxEdge: $0) } ?? rotated
                            let u = folder.appendingPathComponent("\(stem).jpg")
                            try ImageFiles.writeJPEG(Converter.render8(sized, params), width: sized.width,
                                                     height: sized.height, to: u, quality: o.quality / 100)
                            out.append(u)
                        }
                    }
                    return out
                }.value
                written += urls
                f.phase = .exported
            } catch {
                message = error.localizedDescription
                break
            }
        }
        if reveal, !written.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(written) }
        return written
    }

    /// Saves the selected scans as base TIFFs (or raw, for the converter) and opens them.
    func open(_ frames: [Frame], in target: OpenTarget) async {
        let urls = await export(frames, ExportOptions(formats: [target.wantsRaw ? .raw : .baseTIFF]), reveal: false)
        guard !urls.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else { return }
        _ = try? await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func openWithOtherApp(_ frames: [Frame]) async {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let urls = await export(frames, ExportOptions(formats: [.baseTIFF]), reveal: false)
        guard !urls.isEmpty else { return }
        _ = try? await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
