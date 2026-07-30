import SwiftUI

/// Nebelung palette: the desaturated Catppuccin variant shared across the
/// nebelhaus rice (nebelung, pounce, …). Flat surfaces, grey neutrals, muted
/// pastel accents, no shadows.
///
/// A static façade over the **active** palette, so every view keeps reading
/// `Rice.text` / `Rice.base` while the colors themselves come from
/// `RicePalette` — one of the four compiled-in nebelung variants, or a JSON file
/// in `~/.config/trill/themes/`. The colors in a `RicePalette` are built once
/// when it's applied, so a read here is a load and a field access, not a hex
/// parse: no cost at the call site versus the `static let` this replaced.
enum Rice {
    /// The palette everything paints with. Written only from the main actor
    /// (`apply(_:)`, from `RicedRoot` as it renders); every read is a view body,
    /// also on the main actor.
    nonisolated(unsafe) private(set) static var current: RicePalette = .nebelung

    /// Swap the active palette. Views don't observe this — `RicedRoot` rebuilds
    /// its subtree on the theme name, which is what makes a switch visible.
    @MainActor
    static func apply(_ palette: RicePalette) {
        current = palette
    }

    static var crust: Color { current.crust }
    static var mantle: Color { current.mantle }
    static var base: Color { current.base }
    static var surface0: Color { current.surface0 }
    static var surface1: Color { current.surface1 }
    static var surface2: Color { current.surface2 }
    static var overlay0: Color { current.overlay0 }
    static var overlay1: Color { current.overlay1 }
    static var text: Color { current.text }
    static var subtext1: Color { current.subtext1 }
    static var subtext0: Color { current.subtext0 }

    static var mauve: Color { current.mauve }
    static var blue: Color { current.blue }
    static var lavender: Color { current.lavender }
    static var sapphire: Color { current.sapphire }
    static var sky: Color { current.sky }
    static var teal: Color { current.teal }
    static var green: Color { current.green }
    static var yellow: Color { current.yellow }
    static var peach: Color { current.peach }
    static var maroon: Color { current.maroon }
    static var red: Color { current.red }
    static var pink: Color { current.pink }

    /// Is the active palette light? Drives `preferredColorScheme` (so AppKit's
    /// own text fields, scrollers, and menus match) and shadow weight.
    static var isLight: Bool { current.isLight }

    /// A drop shadow that works in both polarities. `alpha` is the dark-palette
    /// value; on a light palette the same black at the same weight reads as
    /// dirt, so it's pulled back to a third — light UI separates by hairline and
    /// fill, not by depth.
    static func shadow(_ alpha: Double) -> Color {
        .black.opacity(current.isLight ? alpha * 0.35 : alpha)
    }

    /// The dim behind a modal panel (command palette, search, library, cheat
    /// sheet). Same reasoning as `shadow(_:)` in reverse: 38% black over a latte
    /// doesn't read as "the panel is in front", it reads as the window turning
    /// grey, so a light palette gets a much thinner veil.
    static func scrim(_ alpha: Double = 0.38) -> Color {
        .black.opacity(current.isLight ? alpha * 0.45 : alpha)
    }

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
    // Computed, not a `let`: a stored default would freeze whichever palette was
    // active the first time it was touched.
    static var defaultValue: Color { Rice.mauve }
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
