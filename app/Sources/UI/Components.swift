import SwiftUI

// MARK: - Cards

struct GlassCard<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Glass())
    }
}

struct Glass: View {
    var radius: CGFloat = 24
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Theme.surface)
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 15, y: 10)
    }
}

struct CardKey: View {
    let text: String
    var body: some View { Text(text).font(.s).foregroundStyle(Theme.text) }
}

struct Dim: View {
    let text: String
    var body: some View { Text(text).font(.s).foregroundStyle(Theme.textDim) }
}

/// The head card: title in two tints with a slow glow behind it.
struct HeadCard: View {
    let title: String
    let subtitle: String
    let status: [String]
    var busy = false
    let count: String
    let countSup: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(Theme.text)
                Text(subtitle).foregroundStyle(Theme.textDim)
            }
            .font(.l)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(status.enumerated()), id: \.offset) { i, line in
                        HStack(spacing: 6) {
                            if i == 0 { Circle().fill(busy ? Theme.accent : Theme.ok).frame(width: 8, height: 8) }
                            Text(line)
                        }
                    }
                }
                .font(.s).foregroundStyle(Theme.textDim)
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 4) {
                    Text(count).font(.pixel(48)).foregroundStyle(Theme.text)
                    Text(countSup).font(.s).foregroundStyle(Theme.textDim)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(alignment: .topTrailing) { Blob().offset(x: 88, y: -72) }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(Glass())
    }
}

struct Blob: View {
    @State private var phase = false
    var body: some View {
        Ellipse()
            .fill(LinearGradient(colors: [Color(hex: 0xF4733F), Color(hex: 0xC9583A), Color(hex: 0x8A4D6B)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 220, height: 190)
            .rotationEffect(.degrees(phase ? 24 : -16))
            .offset(x: phase ? -60 : 0, y: phase ? 40 : 0)
            .blur(radius: 36)
            .opacity(0.7)
            .onAppear { withAnimation(.easeInOut(duration: 20).repeatForever(autoreverses: true)) { phase = true } }
            .allowsHitTesting(false)
    }
}

// MARK: - Buttons

struct ChipStyle: ButtonStyle {
    enum Kind { case normal, on, primary }
    var kind: Kind = .normal
    var height: CGFloat = 40
    var wide = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .s : .m)
            .lineLimit(1)
            .padding(.horizontal, small ? 12 : 16)
            .frame(height: height)
            .frame(maxWidth: wide ? .infinity : nil)
            .foregroundStyle(kind == .on ? Theme.bg : (kind == .primary ? .white : Theme.text))
            .background(Capsule().fill(background(configuration.isPressed)))
            .contentShape(Capsule())
    }

    private func background(_ pressed: Bool) -> Color {
        switch kind {
        case .normal: return pressed ? .white.opacity(0.12) : Theme.surface2
        case .on: return Theme.text
        case .primary: return pressed ? Color(hex: 0xF28B4F) : Theme.accent
        }
    }
}

extension View {
    func chip(_ kind: ChipStyle.Kind = .normal, wide: Bool = false, height: CGFloat = 40, small: Bool = false) -> some View {
        buttonStyle(ChipStyle(kind: kind, height: height, wide: wide, small: small))
    }
}

// MARK: - Segmented

struct Seg<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var small = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, label in
                Button { selection = value } label: {
                    Text(label)
                        .font(small ? .s : .m)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: small ? 28 : 40)
                        .foregroundStyle(selection == value ? Theme.bg : Theme.textFaint)
                        .background(Capsule().fill(selection == value ? Theme.text : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(small ? 2 : 4)
        .background(Capsule().fill(Theme.surface2))
    }
}

// MARK: - Bar slider

/// The pill slider from the training plan: the filled part carries the label,
/// the value sits on the right. Double-click resets.
struct BarSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = { String(format: "%+.0f", $0) }
    var step: Double = 1

    var body: some View {
        GeometryReader { g in
            let f = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let on = abs(value - defaultValue) > step / 2
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surface2)
                // The fill follows the pointer over the whole width; it never gets
                // narrower than a pill so the ends stay round.
                Capsule()
                    .fill(on ? Theme.fillOn : Theme.fill)
                    .frame(width: max(48, g.size.width * f))
                HStack {
                    Text(label).padding(.leading, 20)
                    Spacer()
                    Text(format(value)).font(.pixel(16)).foregroundStyle(on ? Theme.text : Theme.textFaint).padding(.trailing, 20)
                }
                .font(.m)
                .foregroundStyle(Theme.text)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                let x = d.location.x / max(1, g.size.width)
                let raw = range.lowerBound + min(1, max(0, x)) * (range.upperBound - range.lowerBound)
                value = (raw / step).rounded() * step
            })
            .onTapGesture(count: 2) { value = defaultValue }
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { dir in
            value = min(range.upperBound, max(range.lowerBound, value + (dir == .increment ? step : -step) * 5))
        }
    }
}

// MARK: - Switch

struct PillSwitch: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 16) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Theme.accent : .white.opacity(0.12))
                    Circle().fill(configuration.isOn ? .white : Theme.textFaint).padding(3)
                }
                .frame(width: 44, height: 26)
                .animation(.easeOut(duration: 0.15), value: configuration.isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.m).foregroundStyle(Theme.text)
                if let detail { Dim(text: detail) }
            }
        }
        .toggleStyle(PillSwitch())
    }
}

// MARK: - Phase dots

/// Four dots per frame: preview, queued, scanned, exported.
/// Filled = done, light = busy now, rings = skipped.
struct PhaseDots: View {
    var filled: Int
    var busy: Int?
    var skipped = false
    var size: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(fill(i))
                    .overlay { if skipped { Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1.5) } }
                    .background { if busy == i { Circle().fill(Theme.accent.opacity(0.18)).padding(-3) } }
                    .frame(width: size, height: size)
            }
        }
    }

    private func fill(_ i: Int) -> Color {
        if skipped { return .clear }
        if busy == i { return Theme.accent.opacity(0.45) }
        return i < filled ? Theme.accent : .white.opacity(0.14)
    }
}

/// The orange status pill in the toolbar.
struct ProgressPill<Trailing: View>: View {
    let text: String
    let progress: Double
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.m).monospacedDigit()
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule().fill(Theme.accent).frame(width: 120 * min(1, max(0, progress)))
            }
            .frame(width: 120, height: 4)
            trailing
        }
        .foregroundStyle(Theme.accentText)
        .padding(.leading, 16).padding(.trailing, 8)
        .frame(height: 40)
        .background(Capsule().fill(Theme.accent.opacity(0.16)))
    }
}

/// Looks like a text field and shows a folder; clicking it runs `open`
/// (in the export sheet: choose another folder).
struct FolderBox: View {
    let url: URL
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
            .font(.m)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(Capsule().fill(Theme.surface2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Choose a folder")
    }
}

struct FieldBox: View {
    @Binding var text: String
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(.m)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 20)
            .frame(height: 48)
            .background(Capsule().fill(Theme.surface2))
    }
}
