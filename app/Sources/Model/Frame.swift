import Foundation
import CoreGraphics
import Observation

/// Base edit: what you do to get a good starting point. Finishing work
/// (dust, retouching, local edits) happens later in another app.
struct EditSettings: Equatable, Sendable {
    var exposure = 0.0      // -100...100
    var contrast = 30.0     // 0...100
    var black = 0.0         // -50...50
    var white = 0.0         // -50...50
    var temp = 0.0          // -100...100
    var tint = 0.0          // -100...100
    var saturation = 100.0  // 0...200
    /// From the grey picker: per-channel shift so a picked spot is neutral.
    var wb: [Double] = [0, 0, 0]
}

extension EditSettings {
    private static let fields: [WritableKeyPath<EditSettings, Double>] =
        [\.exposure, \.contrast, \.black, \.white, \.temp, \.tint, \.saturation]

    /// This edit with the settings that differ between `old` and `new` set to
    /// their new value; the rest stays.
    func applying(changesFrom old: EditSettings, to new: EditSettings) -> EditSettings {
        var out = self
        for k in Self.fields where old[keyPath: k] != new[keyPath: k] { out[keyPath: k] = new[keyPath: k] }
        if old.wb != new.wb { out.wb = new.wb }
        return out
    }
}

enum Phase: Equatable {
    case empty, previewing, previewed, queued, scanning, scanned, exported

    /// Dots filled in the strip: preview, queued, scanned, exported.
    var filledDots: Int {
        switch self {
        case .empty, .previewing: return 0
        case .previewed: return 1
        case .queued, .scanning: return 2
        case .scanned: return 3
        case .exported: return 4
        }
    }

    /// The dot that is busy right now, if any.
    var busyDot: Int? {
        switch self {
        case .previewing: return 0
        case .scanning: return 2
        default: return nil
        }
    }

    var label: String {
        switch self {
        case .empty: return "Not previewed"
        case .previewing: return "Previewing"
        case .previewed: return "Previewed, not in the queue"
        case .queued: return "In the scan queue"
        case .scanning: return "Scanning"
        case .scanned: return "Scanned"
        case .exported: return "Exported"
        }
    }
}

@Observable
final class Frame: Identifiable {
    let number: Int                 // 1...6
    var id: Int { number }
    var phase: Phase = .empty
    var skipped = false
    var progress = 0.0

    /// Scan settings used when this frame has its own (otherwise the roll's apply).
    var ownSettings: ScanSettings?
    /// The base edit is per frame; the conversion is shared by the roll.
    var edit = EditSettings()
    var rotation = 0                // degrees clockwise

    var preview: Image16?           // 800 dpi
    var full: Image16?              // the real scan
    var proxy: Image16?             // downscaled full scan, screen-sized, for live editing
    var histogram: Converter.Histogram?
    /// Film base density measured in this frame's edit source.
    @ObservationIgnored var baseEstimate: [Double]?
    var rawURL: URL?
    var lastExposure: RGBExposure?
    var lastFocus: Int?

    /// The edit source turned the way it is shown, for the stage and the strip.
    /// Made once per source and rotation, so a render never has to rotate.
    @ObservationIgnored var display: Image16?
    @ObservationIgnored var thumb: Image16?

    var negativeImage: CGImage?     // what the scanner saw, stage size
    var negativeThumb: CGImage?
    var positiveImage: CGImage?     // after conversion, stage size
    var positiveThumb: CGImage?
    var error: String?

    /// The stage image is only rendered while the frame is selected; this
    /// marks that it no longer matches the settings.
    @ObservationIgnored var positiveStale = true
    /// Render bookkeeping: the last render asked for and the last one shown.
    @ObservationIgnored var requestedRender = 0
    @ObservationIgnored var shownRender = 0

    init(number: Int) { self.number = number }

    var name: String { String(format: "%02d", number) }
    var isScanned: Bool { phase == .scanned || phase == .exported }
    var editSource: Image16? { proxy ?? preview }

    func reset() {
        phase = .empty; skipped = false; progress = 0
        ownSettings = nil; edit = EditSettings(); rotation = 0
        preview = nil; full = nil; proxy = nil; histogram = nil; baseEstimate = nil; rawURL = nil
        display = nil; thumb = nil; positiveStale = true
        negativeImage = nil; negativeThumb = nil; positiveImage = nil; positiveThumb = nil; error = nil
    }
}
