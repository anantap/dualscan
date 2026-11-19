import Foundation

enum FilmType: String, CaseIterable, Codable, Sendable {
    case color, bw, slide
    var label: String {
        switch self { case .color: return "Color"; case .bw: return "B&W"; case .slide: return "Slide" }
    }
}

/// What the connected scanner can do, read from the driver once it is open.
/// The Dual IV does everything; the Dual III scans at up to 2820 dpi and
/// leaves exposure, focus and multi-sampling to the scanner itself.
struct ScannerCapabilities: Equatable, Sendable {
    /// Offered scan resolutions, lowest first; the last is full resolution.
    var resolutions: [Int]
    var previewDPI: Int
    /// Auto exposure and per-channel exposure times.
    var exposure: Bool
    var autofocus: Bool
    var multiSample: Bool
    /// Whether the scanner pushes the holder out itself.
    var eject: Bool
    /// The Dual IV's front door has a 35 mm and an APS position.
    var apsDoor = false

    var fullDPI: Int { resolutions.last ?? previewDPI }

    static let dualIV = ScannerCapabilities(resolutions: [800, 1600, 3200], previewDPI: 800,
                                            exposure: true, autofocus: true, multiSample: true, eject: true, apsDoor: true)
    static let dualIII = ScannerCapabilities(resolutions: [705, 1410, 2820], previewDPI: 705,
                                             exposure: false, autofocus: false, multiSample: false, eject: true)

    /// Settings this scanner can do: the nearest resolution it offers, and
    /// nothing it can't do switched on.
    func fitting(_ s: ScanSettings) -> ScanSettings {
        var s = s
        if !resolutions.contains(s.dpi) {
            s.dpi = resolutions.min { abs($0 - s.dpi) < abs($1 - s.dpi) } ?? s.dpi
        }
        if !exposure { s.autoExposure = true }
        if !autofocus { s.autofocus = false }
        if !multiSample { s.multiSample = false }
        return s
    }
}

/// Per-channel exposure time in the Dual IV's units (54...2033; 100 = calibration).
struct RGBExposure: Codable, Equatable, Sendable {
    var r = 100, g = 100, b = 100
    static let range = 54...2033
}

/// What to scan for one frame. Everything here happens inside the scanner,
/// so it has to be decided before the scan.
struct ScanSettings: Equatable, Sendable {
    var dpi = 3200
    var autoExposure = true
    var exposure = RGBExposure()
    var autofocus = true
    var multiSample = false

    func summary(_ caps: ScannerCapabilities) -> String {
        var parts = ["\(dpi) dpi"]
        if caps.exposure { parts.append(autoExposure ? "auto exposure" : "manual exposure") }
        if autofocus { parts.append("AF") }
        if multiSample { parts.append("multi-sample") }
        return parts.joined(separator: " · ")
    }
}

struct ScanRequest: Sendable {
    var frame: Int          // 1...6
    var settings: ScanSettings
    var preview: Bool
}

struct ScanResult: Sendable {
    var image: Image16
    var exposure: RGBExposure?
    var focus: Int?
}

enum ScannerError: LocalizedError {
    case noHolder
    case cancelled
    case sane(String)

    var errorDescription: String? {
        switch self {
        case .noHolder: return "There is no film holder in the scanner."
        case .cancelled: return "Cancelled."
        case .sane(let s): return s
        }
    }
}

/// The scanner as the app sees it. One real implementation (SANE) and one
/// simulated one, so the app can be used without the hardware.
protocol ScannerDevice: AnyObject {
    var displayName: String { get }
    /// What the scanner can do; known once it is open.
    var capabilities: ScannerCapabilities { get }
    /// Opens the device. For the Dual IV this includes the driver's own lamp
    /// wait and a first calibration.
    func open() async throws
    /// Whether a film holder is in the scanner.
    func holderPresent() async -> Bool
    func scan(_ request: ScanRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ScanResult
    func eject() async throws
    /// Stops a running scan; safe to call from any thread.
    func cancel()
    func close()
}
