import Foundation

/// A stand-in Dual IV that produces believable film scans, so the whole app
/// can be used without the hardware. Frame 6 is left blank (unexposed film).
final class SimulatedScanner: ScannerDevice, @unchecked Sendable {
    let displayName = "Simulated Dual IV"
    var film: FilmType
    private let lock = NSLock()
    private var cancelRequested = false
    private var holderInsertedAt: Date?

    init(film: FilmType) { self.film = film }

    func open() async throws {
        try await Task.sleep(for: .seconds(2))
        // The "holder" goes in a few seconds after the scanner is ready.
        holderInsertedAt = Date().addingTimeInterval(4)
    }

    func holderPresent() async -> Bool {
        guard let t = holderInsertedAt else { return false }
        return Date() >= t
    }

    func eject() async throws {
        try await Task.sleep(for: .seconds(1))
        holderInsertedAt = nil
    }

    func cancel() { lock.withLock { cancelRequested = true } }
    func close() {}

    func scan(_ r: ScanRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> ScanResult {
        lock.withLock { cancelRequested = false }
        let dpi = r.preview ? 800 : r.settings.dpi
        var seconds = r.preview ? 1.2 : 2.0 + Double(dpi) / 3200 * 5
        if !r.preview && r.settings.multiSample { seconds *= 3 }
        if !r.preview && r.settings.autofocus { seconds += 1.5 }
        let steps = 40
        for i in 1...steps {
            try await Task.sleep(for: .seconds(seconds / Double(steps)))
            if lock.withLock({ cancelRequested }) { throw ScannerError.cancelled }
            progress(Double(i) / Double(steps))
        }
        let film = self.film
        let image = await Task.detached(priority: .userInitiated) {
            Self.render(frame: r.frame, dpi: dpi, film: film)
        }.value
        return ScanResult(image: image, exposure: RGBExposure(r: 412, g: 980, b: 1240), focus: r.preview ? 0 : 34)
    }

    // MARK: Fake film

    /// 36 × 24 mm at the given resolution.
    static func render(frame: Int, dpi: Int, film: FilmType) -> Image16 {
        let w = Int(36 / 25.4 * Double(dpi)), h = Int(24 / 25.4 * Double(dpi))
        var out = [UInt16](repeating: 0, count: w * h * 3)
        let base: [Double] = [0.22, 0.52, 0.82]          // orange mask: blue is densest
        let gamma = 0.62
        out.withUnsafeMutableBufferPointer { o in
            let op = o.baseAddress!
            DispatchQueue.concurrentPerform(iterations: h) { y in
                var seed = UInt64(y &* 2654435761) ^ UInt64(frame)
                for x in 0..<w {
                    let u = Double(x) / Double(w), v = Double(y) / Double(h)
                    var L = scene(frame, u, v)
                    // a little grain
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    let g = (Double(seed >> 40) / Double(1 << 24) - 0.5) * 0.04
                    L = L.map { max(0.0005, $0 * (1 + g)) }
                    var px = [0.0, 0.0, 0.0]
                    switch film {
                    case .slide:
                        px = L.map { min(1, $0) }
                    case .bw:
                        let m = 0.3 * L[0] + 0.55 * L[1] + 0.15 * L[2]
                        let d = 0.15 + gamma * max(0, log10(m) + 2.2)
                        px = Array(repeating: pow(10, -d) * pow(10, 0.15) * 0.92, count: 3)
                    case .color:
                        for c in 0..<3 {
                            let d = base[c] + gamma * max(0, log10(L[c]) + 2.2)
                            px[c] = pow(10, -d) * pow(10, base[0]) * 0.92
                        }
                    }
                    let k = (y * w + x) * 3
                    for c in 0..<3 { op[k + c] = UInt16(min(65535, max(0, px[c] * 65535))) }
                }
            }
        }
        return Image16(width: w, height: h, data: out)
    }

    /// Linear scene light, 0...1, for six simple pictures.
    private static func scene(_ frame: Int, _ u: Double, _ v: Double) -> [Double] {
        func mix(_ a: [Double], _ b: [Double], _ t: Double) -> [Double] { (0..<3).map { a[$0] + (b[$0] - a[$0]) * t } }
        let sky = mix([0.30, 0.45, 0.75], [0.75, 0.80, 0.85], v)
        func hill(_ y0: Double, _ amp: Double, _ f: Double, _ ph: Double) -> Double { y0 + amp * sin(u * f + ph) }
        switch frame {
        case 1:
            if v > hill(0.62, 0.05, 6, 0.3) { return [0.08, 0.16, 0.06] }
            return sky
        case 2:
            let d = hypot(u - 0.5, (v - 0.45) * 1.5)
            if d < 0.22 { return [0.55, 0.38, 0.30] }
            return mix([0.25, 0.20, 0.15], [0.10, 0.08, 0.06], v)
        case 3:
            if hypot(u - 0.73, v - 0.28) < 0.08 { return [1.0, 0.92, 0.70] }
            if v > hill(0.50, 0.06, 4, 1.0) { return v > hill(0.72, 0.04, 7, 0.2) ? [0.05, 0.10, 0.04] : [0.12, 0.22, 0.09] }
            return mix([0.55, 0.50, 0.55], [0.95, 0.70, 0.45], v)
        case 4:
            if (u > 0.2 && u < 0.42 && v > 0.22) || (u > 0.55 && u < 0.78 && v > 0.35) { return [0.35, 0.25, 0.18] }
            return mix(sky, [0.4, 0.4, 0.42], max(0, v - 0.8) * 5)
        case 5:
            let peak = 0.75 - 0.45 * max(0, 1 - abs(u - 0.4) * 3) - 0.3 * max(0, 1 - abs(u - 0.75) * 4)
            if v > peak { return v > 0.85 ? [0.15, 0.18, 0.12] : [0.30, 0.32, 0.35] }
            return sky
        default:
            return [0.0, 0.0, 0.0]   // unexposed
        }
    }
}
