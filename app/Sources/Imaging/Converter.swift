import Foundation
import CoreGraphics

/// Negative → positive, ported from the Negatief Converter (converter-core.js).
///
/// As with an analogue print:
///  1. Scanner value (linear transmission) → optical density D = -log10(T).
///  2. Per channel, normalise D between the thinnest point (film base, shadows)
///     and the densest point (highlights). This removes the orange mask.
///  3. Send the result through an S-shaped "paper curve" to sRGB.
enum Converter {
    static let maxV = 65535.0
    static let bins = 2048
    static let dMax = 5.0

    /// Density for every 16-bit value.
    static let dlut: [Float] = (0..<65536).map { Float(-log10(Double(max($0, 1)) / maxV)) }

    struct Histogram: Sendable {
        var counts: [[UInt32]] = Array(repeating: Array(repeating: 0, count: Converter.bins), count: 3)
        var total = 0

        static func merged(_ list: [Histogram]) -> Histogram {
            var out = Histogram()
            for h in list {
                for c in 0..<3 { for i in 0..<Converter.bins { out.counts[c][i] += h.counts[c][i] } }
                out.total += h.total
            }
            return out
        }
    }

    struct Analysis: Sendable, Equatable {
        var lo: [Double]
        var hi: [Double]
    }

    /// Density histogram per channel, leaving out a border fraction.
    static func histogram(_ img: Image16, border: Double = 0.02) -> Histogram {
        var h = Histogram()
        let k = Double(bins) / dMax
        let x0 = Int(Double(img.width) * border), x1 = img.width - x0
        let y0 = Int(Double(img.height) * border), y1 = img.height - y0
        let hi = UInt16(maxV * 0.985)
        img.data.withUnsafeBufferPointer { d in
            for y in y0..<y1 {
                var i = (y * img.width + x0) * 3
                for _ in x0..<x1 {
                    let r = d[i], g = d[i + 1], b = d[i + 2]
                    i += 3
                    // Skip blown-through light (sprockets, leaks) and pure black (holder).
                    if (r >= hi && g >= hi && b >= hi) || (r < 3 && g < 3 && b < 3) { continue }
                    h.counts[0][min(bins - 1, Int(Double(dlut[Int(r)]) * k))] += 1
                    h.counts[1][min(bins - 1, Int(Double(dlut[Int(g)]) * k))] += 1
                    h.counts[2][min(bins - 1, Int(Double(dlut[Int(b)]) * k))] += 1
                    h.total += 1
                }
            }
        }
        return h
    }

    static func percentile(_ h: [UInt32], total: Int, _ p: Double) -> Double {
        let target = Double(total) * p
        var acc = 0.0
        for i in 0..<h.count {
            acc += Double(h[i])
            if acc >= target { return (Double(i) + 0.5) * dMax / Double(bins) }
        }
        return dMax
    }

    /// The film base: the thinnest part of the scan, including its edge.
    static func estimateBase(_ img: Image16) -> [Double]? {
        let h = histogram(img, border: 0)
        guard h.total > 0 else { return nil }
        return (0..<3).map { percentile(h.counts[$0], total: h.total, 0.0005) }
    }

    /// Mean density around a point, in source pixels.
    static func sampleDensity(_ img: Image16, x: Int, y: Int, radius r: Int = 6) -> [Double] {
        var s = [0.0, 0.0, 0.0]
        var n = 0.0
        for yy in max(0, y - r)...min(img.height - 1, y + r) {
            for xx in max(0, x - r)...min(img.width - 1, x + r) {
                let i = (yy * img.width + xx) * 3
                for c in 0..<3 { s[c] += Double(img.data[i + c]) }
                n += 1
            }
        }
        return s.map { -log10(max($0 / n, 1) / maxV) }
    }

    static func analyze(_ h: Histogram?, base: [Double]?, clipLo: Double = 0.002, clipHi: Double = 0.002) -> Analysis {
        var lo = [0.0, 0.0, 0.0], hi = [0.0, 0.0, 0.0]
        for c in 0..<3 {
            guard let h, h.total > 0 else { lo[c] = 0.2; hi[c] = 2.0; continue }
            lo[c] = percentile(h.counts[c], total: h.total, clipLo)
            hi[c] = percentile(h.counts[c], total: h.total, 1 - clipHi)
        }
        if let base, let h, h.total > 0 {
            // The film base sets the colour balance in the shadows; the black point
            // sits at the same fraction between base and highlight for every channel.
            var fr = (0..<3).map { c in max(0, (lo[c] - base[c]) / max(0.05, hi[c] - base[c])) }
            fr.sort()
            let f = fr[1]
            for c in 0..<3 { lo[c] = base[c] + f * (hi[c] - base[c]) }
        }
        for c in 0..<3 where hi[c] - lo[c] < 0.05 { hi[c] = lo[c] + 0.05 }
        return Analysis(lo: lo, hi: hi)
    }

    /// Normalised values (no white balance) at a density, for the grey picker.
    static func normalized(_ an: Analysis, _ D: [Double], positive: Bool) -> [Double] {
        (0..<3).map { (c: Int) -> Double in
            let span = an.hi[c] - an.lo[c]
            return positive ? (an.hi[c] - D[c]) / span : (D[c] - an.lo[c]) / span
        }
    }

    struct Params {
        var lo: [Float]
        var scale: [Float]
        var off: [Float]
        var curve: [Float]
        var sat: Float
        var bw: Bool
    }

    static let nMin: Float = -1, nMax: Float = 2, curveN = 32768
    static let cScale = Float(curveN - 1) / (nMax - nMin)

    static func params(_ an: Analysis, _ s: EditSettings, film: FilmType) -> Params {
        let positive = film == .slide
        let t = 0.0015
        let off = [
            s.exposure * 0.003 + s.wb[0] + s.temp * t,
            s.exposure * 0.003 + s.wb[1] - s.tint * t,
            s.exposure * 0.003 + s.wb[2] - s.temp * t,
        ].map(Float.init)
        let scale = (0..<3).map { c in Float((positive ? -1 : 1) / (an.hi[c] - an.lo[c])) }
        let lo = (positive ? an.hi : an.lo).map(Float.init)

        return Params(lo: lo, scale: scale, off: off, curve: paperCurve(contrast: s.contrast, black: s.black, white: s.white),
                      sat: Float(s.saturation / 100), bw: film == .bw)
    }

    private static let curveLock = NSLock()
    nonisolated(unsafe) private static var curveCache: (key: [Double], curve: [Float])?

    /// Paper curve: n (log exposure, 0..1) → linear light over ~2 log units,
    /// then sRGB, then an S-curve for contrast. Only contrast, black and white
    /// change it, so the last one is kept: most slider moves reuse it.
    static func paperCurve(contrast: Double, black: Double, white: Double) -> [Float] {
        let key = [contrast, black, white]
        if let c = curveLock.withLock({ curveCache }), c.key == key { return c.curve }
        let R = 2.0, floor = pow(10, -R)
        let bp = black / 200, wp = 1 + white / 200
        let k = 0.01 + contrast * 0.08
        func sig(_ x: Double) -> Double { 1 / (1 + exp(-k * (x - 0.5))) }
        let s0 = sig(0), s1 = sig(1)
        var curve = [Float](repeating: 0, count: curveN)
        for i in 0..<curveN {
            let n = Double(nMin) + Double(i) / Double(cScale)
            let x = (n - bp) / (wp - bp)
            var lin = (pow(10, (x - 1) * R) - floor) / (1 - floor)
            lin = min(1, max(0, lin))
            var y = lin <= 0.0031308 ? lin * 12.92 : 1.055 * pow(lin, 1 / 2.4) - 0.055
            y = (sig(y) - s0) / (s1 - s0)
            curve[i] = Float(min(1, max(0, y)))
        }
        curveLock.withLock { curveCache = (key, curve) }
        return curve
    }

    /// Renders to sRGB. `bits` 8 gives RGBA bytes, 16 gives RGB 16-bit samples.
    static func render8(_ img: Image16, _ P: Params) -> [UInt8] {
        var out = [UInt8](repeating: 255, count: img.width * img.height * 4)
        out.withUnsafeMutableBufferPointer { o in
            let op = o.baseAddress!
            renderRows(img, P) { p, r, g, b in
                op[p * 4] = UInt8(r * 255 + 0.5)
                op[p * 4 + 1] = UInt8(g * 255 + 0.5)
                op[p * 4 + 2] = UInt8(b * 255 + 0.5)
            }
        }
        return out
    }

    static func render16(_ img: Image16, _ P: Params) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: img.width * img.height * 3)
        out.withUnsafeMutableBufferPointer { o in
            let op = o.baseAddress!
            renderRows(img, P) { p, r, g, b in
                op[p * 3] = UInt16(r * 65535 + 0.5)
                op[p * 3 + 1] = UInt16(g * 65535 + 0.5)
                op[p * 3 + 2] = UInt16(b * 65535 + 0.5)
            }
        }
        return out
    }

    private static func renderRows(_ img: Image16, _ P: Params, write: (Int, Float, Float, Float) -> Void) {
        let top = curveN - 1
        let doSat = !P.bw && abs(P.sat - 1) > 1e-3
        dlut.withUnsafeBufferPointer { D in
            P.curve.withUnsafeBufferPointer { C in
                img.data.withUnsafeBufferPointer { d in
                    let w = img.width
                    DispatchQueue.concurrentPerform(iterations: img.height) { y in
                        for x in 0..<w {
                            let p = y * w + x, i = p * 3
                            var nr = (D[Int(d[i])] - P.lo[0]) * P.scale[0] + P.off[0]
                            var ng = (D[Int(d[i + 1])] - P.lo[1]) * P.scale[1] + P.off[1]
                            var nb = (D[Int(d[i + 2])] - P.lo[2]) * P.scale[2] + P.off[2]
                            if P.bw { let m = 0.25 * nr + 0.5 * ng + 0.25 * nb; nr = m; ng = m; nb = m }
                            let ir = min(top, max(0, Int((nr - nMin) * cScale)))
                            let ig = min(top, max(0, Int((ng - nMin) * cScale)))
                            let ib = min(top, max(0, Int((nb - nMin) * cScale)))
                            var r = C[ir], g = C[ig], b = C[ib]
                            if doSat {
                                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                                r = min(1, max(0, l + (r - l) * P.sat))
                                g = min(1, max(0, l + (g - l) * P.sat))
                                b = min(1, max(0, l + (b - l) * P.sat))
                            }
                            write(p, r, g, b)
                        }
                    }
                }
            }
        }
    }
}
