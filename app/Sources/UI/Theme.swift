import SwiftUI
import CoreText

/// The Negatief Converter's dark language: Geist, glass on mist, orange.
enum Theme {
    static let bg = Color(hex: 0x121211)
    static let surround = Color(hex: 0x191918)
    static let surface = Color(red: 52 / 255, green: 50 / 255, blue: 46 / 255).opacity(0.5)
    static let surface2 = Color.white.opacity(0.06)
    static let fill = Color(red: 92 / 255, green: 88 / 255, blue: 80 / 255).opacity(0.55)
    static let fillOn = Color(red: 239 / 255, green: 125 / 255, blue: 60 / 255).opacity(0.42)
    static let text = Color(hex: 0xECEBE6)
    static let textDim = Color(hex: 0xA29F97)
    static let textFaint = Color(hex: 0x8F8C84)
    static let accent = Color(hex: 0xEF7D3C)
    static let accentText = Color(hex: 0xF39A63)
    static let ok = Color(hex: 0x7FC28A)
    static let line = Color.white.opacity(0.08)

    static func registerFonts() {
        guard let dir = Bundle.main.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        CTFontManagerRegisterFontURLs(files as CFArray, .process, true, nil)
    }
}

extension Font {
    static func geist(_ size: CGFloat) -> Font { .custom("Geist-Regular", size: size) }
    static func pixel(_ size: CGFloat) -> Font { .custom("GeistPixel-Regular", size: size) }
    static let s = Font.geist(12)
    static let m = Font.geist(16)
    static let l = Font.geist(24)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Mist behind everything: cool slate top left, glowing orange right, olive below.
struct MistBackground: View {
    var body: some View {
        GeometryReader { g in
            ZStack {
                Theme.bg
                RadialGradient(colors: [Color(hex: 0x1F2428), .clear], center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: g.size.width * 0.7)
                RadialGradient(colors: [Color(hex: 0x2B1E16), .clear], center: UnitPoint(x: 1, y: 0.55), startRadius: 0, endRadius: g.size.width * 0.5)
                RadialGradient(colors: [Color(hex: 0x1D1F19), .clear], center: UnitPoint(x: 0, y: 1), startRadius: 0, endRadius: g.size.width * 0.6)
            }
        }
        .ignoresSafeArea()
    }
}
