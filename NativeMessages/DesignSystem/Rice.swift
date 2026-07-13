import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// Nebelung palette: the desaturated Catppuccin Mocha variant shared across the
/// nebelhaus rice (nebelung, pounce, …). Flat surfaces, grey neutrals, muted
/// pastel accents, no shadows.
enum Rice {
    static let crust = Color(hex: 0x121212)
    static let mantle = Color(hex: 0x191919)
    static let base = Color(hex: 0x202020)
    static let surface0 = Color(hex: 0x343434)
    static let surface1 = Color(hex: 0x494949)
    static let surface2 = Color(hex: 0x5C5C5C)
    static let overlay0 = Color(hex: 0x717171)
    static let overlay1 = Color(hex: 0x858585)
    static let text = Color(hex: 0xD7D7D7)
    static let subtext1 = Color(hex: 0xC3C3C3)
    static let subtext0 = Color(hex: 0xAEAEAE)

    static let mauve = Color(hex: 0xC9A8F1)
    static let blue = Color(hex: 0x8DB4F3)
    static let lavender = Color(hex: 0xB5BFF8)
    static let sapphire = Color(hex: 0x7DC6E7)
    static let sky = Color(hex: 0x91DBE8)
    static let teal = Color(hex: 0x9BE0D5)
    static let green = Color(hex: 0xABE1A6)
    static let yellow = Color(hex: 0xF7E2B5)
    static let peach = Color(hex: 0xF5B58E)
    static let maroon = Color(hex: 0xE6A3AD)
    static let red = Color(hex: 0xED8FA9)
    static let pink = Color(hex: 0xF2C4E5)

    static let accentNames = [
        "mauve", "blue", "lavender", "sapphire", "sky", "teal",
        "green", "yellow", "peach", "maroon", "red", "pink",
    ]

    static func accent(named name: String) -> Color {
        switch name {
        case "blue": blue
        case "lavender": lavender
        case "sapphire": sapphire
        case "sky": sky
        case "teal": teal
        case "green": green
        case "yellow": yellow
        case "peach": peach
        case "maroon": maroon
        case "red": red
        case "pink": pink
        default: mauve
        }
    }

    /// Stable per-entity accent for avatars and sender names. Uses djb2 rather
    /// than Hashable so the color survives relaunches.
    static func accent(seededBy seed: String) -> Color {
        let palette: [Color] = [mauve, blue, sapphire, teal, green, peach, red, pink, lavender, sky]
        var hash: UInt64 = 5381
        for byte in seed.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return palette[Int(hash % UInt64(palette.count))]
    }
}

// MARK: - Environment

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

private struct RiceAccentKey: EnvironmentKey {
    static let defaultValue = Rice.mauve
}

extension EnvironmentValues {
    /// Whole-app zoom factor driven by ⌘+ / ⌘− / ⌘0.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }

    /// User-selected accent from Settings.
    var riceAccent: Color {
        get { self[RiceAccentKey.self] }
        set { self[RiceAccentKey.self] = newValue }
    }
}

enum UIZoom {
    static let range: ClosedRange<Double> = 0.8...1.6
    static let step = 0.1
}

// MARK: - Type scale

private struct RiceFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

private struct RiceSectionHeader: ViewModifier {
    @Environment(\.uiScale) private var scale

    func body(content: Content) -> some View {
        content
            .font(.system(size: 11 * scale, weight: .semibold, design: .rounded))
            .kerning(0.6)
            .textCase(.uppercase)
            .foregroundStyle(Rice.subtext0)
    }
}

extension View {
    /// Zoom-aware rounded system font; the app's only font entry point.
    func riceFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .rounded) -> some View {
        modifier(RiceFont(size: size, weight: weight, design: design))
    }

    /// Small-caps section label, pounce-style.
    func riceSectionHeader() -> some View {
        modifier(RiceSectionHeader())
    }
}

// MARK: - Display density

enum DisplayDensity: String, CaseIterable, Identifiable {
    case compact
    case comfortable
    case spacious

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .comfortable: "Comfortable"
        case .spacious: "Spacious"
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .compact: 5
        case .comfortable: 7
        case .spacious: 10
        }
    }

    var timelineSpacing: CGFloat {
        switch self {
        case .compact: 2
        case .comfortable: 3
        case .spacious: 5
        }
    }
}

// MARK: - Compact relative time

enum CompactTime {
    /// Short sidebar timestamps: "now", "5m", "3h", "2d", "4w", "Jan 12", "Jan 2024".
    static func string(from date: Date, relativeTo now: Date = .now) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        if seconds < 35 * 86_400 { return "\(Int(seconds / (7 * 86_400)))w" }
        let calendar = Calendar.current
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).year())
    }
}
