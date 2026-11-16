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
