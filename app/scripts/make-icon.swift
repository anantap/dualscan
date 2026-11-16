// Draws the Dual Scan app icon (1024 px) in the app's own language:
// a dark tile with mist, an orange glow and the four phase dots in a 2 × 2 grid.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit
import CoreImage

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// The macOS tile: 824 px with a continuous-looking corner.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
ctx.addPath(tilePath); ctx.setFillColor(color(0x121211)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()

// Mist: slate top left, orange right, olive below.
func glow(_ c: CGPoint, _ r: CGFloat, _ hex: UInt32, _ a: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(hex, a), color(hex, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
}
glow(CGPoint(x: 160, y: 900), 620, 0x2A3238, 1)
glow(CGPoint(x: 924, y: 420), 520, 0x3A2416, 1)
glow(CGPoint(x: 120, y: 120), 560, 0x22251C, 1)

// The blob: a soft orange glow, top right, like the head cards.
let blob = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
blob.addEllipse(in: CGRect(x: 560, y: 600, width: 420, height: 360))
blob.clip()
let bg = CGGradient(colorsSpace: space, colors: [color(0xF4733F), color(0xC9583A), color(0x8A4D6B)] as CFArray, locations: [0, 0.55, 1])!
blob.drawLinearGradient(bg, start: CGPoint(x: 600, y: 960), end: CGPoint(x: 980, y: 600), options: [])
let blurred = CIImage(cgImage: blob.makeImage()!).applyingGaussianBlur(sigma: 70).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
let blobImage = CIContext().createCGImage(blurred, from: CGRect(x: 0, y: 0, width: S, height: S))!
ctx.setAlpha(0.85)
ctx.draw(blobImage, in: CGRect(x: 0, y: 0, width: S, height: S))
ctx.setAlpha(1)

// The four phase dots in a 2 × 2 grid: three done, one busy (bottom right).
let d: CGFloat = 176, gap: CGFloat = 64
let origin = (S - (2 * d + gap)) / 2
for i in 0..<4 {
    let col = CGFloat(i % 2), row = CGFloat(1 - i / 2)          // fill top row first
    let r = CGRect(x: origin + col * (d + gap), y: origin + row * (d + gap), width: d, height: d)
    if i == 3 {
        ctx.setFillColor(color(0xEF7D3C, 0.16)); ctx.fillEllipse(in: r.insetBy(dx: -26, dy: -26))
        ctx.setFillColor(color(0xEF7D3C, 0.48)); ctx.fillEllipse(in: r)
    } else {
        ctx.setFillColor(color(0xEF7D3C)); ctx.fillEllipse(in: r)
    }
}

// A faint top highlight on the tile edge
ctx.addPath(tilePath)
ctx.setStrokeColor(color(0xFFFFFF, 0.08)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
