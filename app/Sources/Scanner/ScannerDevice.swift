import Foundation

enum FilmType: String, CaseIterable, Codable, Sendable {
    case color, bw, slide
    var label: String {
        switch self { case .color: return "Color"; case .bw: return "B&W"; case .slide: return "Slide" }
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

    var summary: String {
        var parts = ["\(dpi) dpi", autoExposure ? "auto exposure" : "manual exposure"]
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
