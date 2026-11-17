import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFiles {
    enum FileError: LocalizedError {
        case write(URL)
        var errorDescription: String? {
            switch self { case .write(let u): return "Could not write \(u.lastPathComponent)" }
        }
    }

    /// Reads a 16-bit RGB TIFF written by `writeTIFF16` (a raw scan) back, without changing its values.
    static func readTIFF16(_ url: URL) -> Image16? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let (w, h) = (image.width, image.height)
        var rgbx = [UInt16](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgbx.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.linearSRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt16](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgbx[i * 4]; rgb[i * 3 + 1] = rgbx[i * 4 + 1]; rgb[i * 3 + 2] = rgbx[i * 4 + 2]
        }
        return Image16(width: w, height: h, data: rgb)
    }

    /// 16-bit RGB TIFF. `linear` tags it as linear (raw scans); otherwise sRGB.
    static func writeTIFF16(_ rgb: [UInt16], width: Int, height: Int, to url: URL, linear: Bool) throws {
        let space = CGColorSpace(name: linear ? CGColorSpace.linearSRGB : CGColorSpace.sRGB)!
        let data = rgb.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 48,
                                  bytesPerRow: width * 6, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw FileError.write(url) }
        try write(image, to: url, type: .tiff, properties: [:])
    }

    static func writeJPEG(_ rgba: [UInt8], width: Int, height: Int, to url: URL, quality: Double) throws {
        guard let image = CGImage.rgba8(rgba, width: width, height: height) else { throw FileError.write(url) }
        try write(image, to: url, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    static func jpegData(_ rgba: [UInt8], width: Int, height: Int, quality: Double) -> Data? {
        guard let image = CGImage.rgba8(rgba, width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FileError.write(url)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw FileError.write(url) }
    }
}
