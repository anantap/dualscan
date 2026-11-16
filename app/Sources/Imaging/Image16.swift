import Foundation
import CoreGraphics

/// Linear 16-bit RGB, interleaved, as it comes from the scanner.
struct Image16: Sendable {
    var width: Int
    var height: Int
    var data: [UInt16]

    init(width: Int, height: Int, data: [UInt16]) {
        precondition(data.count == width * height * 3)
        self.width = width
        self.height = height
        self.data = data
    }

    /// Box downscale so the long edge is at most `maxEdge`.
    func downscaled(maxEdge: Int) -> Image16 {
        let f = max(1, Int((Double(max(width, height)) / Double(maxEdge)).rounded(.up)))
        if f == 1 { return self }
        let w = width / f, h = height / f
        var out = [UInt16](repeating: 0, count: w * h * 3)
        let sw = width
        let inv = 1.0 / Double(f * f)
        data.withUnsafeBufferPointer { d in
            out.withUnsafeMutableBufferPointer { o in
                let op = o.baseAddress!
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        var r = 0, g = 0, b = 0
                        for yy in 0..<f {
                            var i = ((y * f + yy) * sw + x * f) * 3
                            for _ in 0..<f {
                                r += Int(d[i]); g += Int(d[i + 1]); b += Int(d[i + 2])
                                i += 3
                            }
                        }
                        let k = (y * w + x) * 3
                        op[k] = UInt16(Double(r) * inv)
                        op[k + 1] = UInt16(Double(g) * inv)
                        op[k + 2] = UInt16(Double(b) * inv)
                    }
                }
            }
        }
        return Image16(width: w, height: h, data: out)
    }

    /// Rotates clockwise by 0, 90, 180 or 270 degrees.
    func rotated(_ degrees: Int) -> Image16 {
        let rot = ((degrees % 360) + 360) % 360
        if rot == 0 { return self }
        let W = (rot == 180) ? width : height
        let H = (rot == 180) ? height : width
        var out = [UInt16](repeating: 0, count: data.count)
        let w = width, h = height
        data.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                let op = o.baseAddress!
                DispatchQueue.concurrentPerform(iterations: H) { y in
                    for x in 0..<W {
                        let sx: Int, sy: Int
                        switch rot {
                        case 90: sx = y; sy = h - 1 - x
                        case 180: sx = w - 1 - x; sy = h - 1 - y
                        default: sx = w - 1 - y; sy = x
                        }
                        let si = (sy * w + sx) * 3, di = (y * W + x) * 3
                        op[di] = s[si]; op[di + 1] = s[si + 1]; op[di + 2] = s[si + 2]
                    }
                }
            }
        }
        return Image16(width: W, height: H, data: out)
    }

    /// The raw negative for display: linear values with a 2.2 gamma, 8-bit RGBA.
    func negativeCGImage() -> CGImage? {
        var lut = [UInt8](repeating: 0, count: 65536)
        for i in 0..<65536 { lut[i] = UInt8(min(255, (pow(Double(i) / 65535, 1 / 2.2) * 255).rounded())) }
        var px = [UInt8](repeating: 255, count: width * height * 4)
        let n = width * height
        data.withUnsafeBufferPointer { d in
            px.withUnsafeMutableBufferPointer { o in
                for p in 0..<n {
                    o[p * 4] = lut[Int(d[p * 3])]
                    o[p * 4 + 1] = lut[Int(d[p * 3 + 1])]
                    o[p * 4 + 2] = lut[Int(d[p * 3 + 2])]
                }
            }
        }
        return CGImage.rgba8(px, width: width, height: height)
    }
}

extension CGImage {
    static func rgba8(_ px: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
