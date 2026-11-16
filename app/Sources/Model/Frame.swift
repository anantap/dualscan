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
    var proxy: Image16?             // downscaled full scan, for live editing
    var histogram: Converter.Histogram?
    var rawURL: URL?
    var lastExposure: RGBExposure?
    var lastFocus: Int?

    var negativeImage: CGImage?     // what the scanner saw
    var positiveImage: CGImage?     // after conversion
    var error: String?

    init(number: Int) { self.number = number }

    var name: String { String(format: "%02d", number) }
    var isScanned: Bool { phase == .scanned || phase == .exported }
    var editSource: Image16? { proxy ?? preview }

    func reset() {
        phase = .empty; skipped = false; progress = 0
        ownSettings = nil; edit = EditSettings(); rotation = 0
        preview = nil; full = nil; proxy = nil; histogram = nil; rawURL = nil
        negativeImage = nil; positiveImage = nil; error = nil
    }
}
