import AppKit
import SiltCore
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Color {
    /// A colour that switches with the system appearance. Each mode has its own chosen step
    /// rather than an automatic inversion, so both stay legible against their own surface.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Palette {
    static let page = Color(light: 0xf9f9f7, dark: 0x121211)
    static let surface = Color(light: 0xfcfcfb, dark: 0x1a1a19)
    static let ink = Color(light: 0x0b0b0b, dark: 0xf0efec)
    static let ink2 = Color(light: 0x52514e, dark: 0xc3c2b7)
    static let muted = Color(light: 0x898781, dark: 0x898781)
    static let hairline = Color(light: 0xe1e0d9, dark: 0x2c2c2a)
    static let free = Color(light: 0xebeae4, dark: 0x262624)
    static let system = Color(light: 0x6f6d68, dark: 0x8a8882)
    static let unseen = Color(light: 0xd6d4cd, dark: 0x3a3936)
    static let smaller = Color(light: 0xd6d4cd, dark: 0x3a3936)

    /// The validated eight-slot categorical palette, in its fixed order, one slot per kind.
    /// Kinds keep their colour whatever their rank, so "Developer" is always orange.
    static func kind(_ k: Kind) -> Color {
        switch k {
        case .apps: Color(light: 0x2a78d6, dark: 0x3987e5)
        case .developer: Color(light: 0xeb6834, dark: 0xd95926)
        case .media: Color(light: 0x1baf7a, dark: 0x199e70)
        case .documents: Color(light: 0xeda100, dark: 0xc98500)
        case .archives: Color(light: 0xe87ba4, dark: 0xd55181)
        case .caches: Color(light: 0x008300, dark: 0x008300)
        case .appData: Color(light: 0x6250d6, dark: 0x9085e9)
        case .other: Color(light: 0xa9a7a0, dark: 0x5f5e5a)
        }
    }

    /// Text set inside a filled tile: white, except near-black on yellow.
    static func label(onKind k: Kind) -> Color {
        k == .documents || k == .other ? Color(light: 0x0b0b0b, dark: 0x0b0b0b) : .white
    }

    /// One-hue sequential ramp for age. In light mode older is darker; in dark mode older is
    /// lighter, so in both the oldest things stand out most from the surface.
    static let ramp: [UInt32] = [0xcde2fb, 0xb7d3f6, 0x9ec5f4, 0x86b6ef, 0x6da7ec, 0x5598e7, 0x3987e5,
                                 0x2a78d6, 0x256abf, 0x1c5cab, 0x184f95, 0x104281, 0x0d366b]

    /// 0 for changed today, 1 for five years or more. Logarithmic, so this year's months get room.
    static func ageFraction(days: Double) -> Double {
        min(1, log1p(max(0, days)) / log1p(1826))
    }

    static func age(_ t: Double) -> Color {
        let i = Int((min(1, max(0, t)) * Double(ramp.count - 1)).rounded())
        return Color(light: ramp[i], dark: ramp[ramp.count - 1 - i])
    }

    static func label(onAge t: Double) -> Color {
        t > 0.5 ? Color(light: 0xffffff, dark: 0x0b0b0b) : Color(light: 0x0b0b0b, dark: 0xffffff)
    }
}

// MARK: - Type that grows with the window

/// Wide windows get bigger type instead of a wider column, so the page stays one easy read.
enum Theme {
    static func scale(forWidth w: CGFloat) -> CGFloat { min(1.3, max(1.0, (w - 120) / 1000)) }
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct SiltFont: ViewModifier {
    @Environment(\.uiScale) private var s
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * s, weight: weight, design: design))
    }
}

extension View {
    func siltFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(SiltFont(size: size, weight: weight, design: design))
    }
}

// MARK: - Small shared pieces

struct SectionHeading: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).siltFont(24, .semibold).foregroundStyle(Palette.ink)
            if let detail {
                Text(detail).siltFont(14).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum CheckState { case on, off, mixed }

struct CheckBox: View {
    @Environment(\.uiScale) private var s
    let state: CheckState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                .font(.system(size: 17 * s))
                .foregroundStyle(state == .off ? Palette.muted : Color.accentColor)
                .frame(width: 22 * s, height: 22 * s)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .on ? "Ticked" : state == .mixed ? "Partly ticked" : "Not ticked")
    }
}

struct Placeholder: View {
    let text: String
    var body: some View {
        Text(text).siltFont(14).foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline))
    }
}

/// Diagonal hatching, for the part of the disk Silt couldn't see: it reads as "unknown"
/// without needing a ninth colour.
struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            ctx.stroke(p, with: .color(Palette.muted.opacity(0.55)), lineWidth: 1)
        }
    }
}

/// Wraps its children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 16
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(width, widest), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
