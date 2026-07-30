import AppKit
import SwiftUI

/// A complete set of colors the UI paints with — one nebelung variant, or any
/// palette a user drops on disk. `Rice.current` is the active one and every
/// `Rice.text` / `Rice.base` read goes through it.
///
/// **Why this exists.** The palette used to be 24 `static let` hex literals, so
/// the only way to change trill's colors was to rebuild it. That put the latte
/// and high-contrast nebelung variants out of reach for anyone who installed
/// with `brew` (and made the rice's `nebelhaus.theme.flavor/contrast` a lie for
/// trill). All four variants are now compiled in — a Homebrew install with an
/// empty `~/.config` can still switch flavor — and any *other* palette resolves
/// to a JSON file at runtime. Same model as pounce (`pkgs/pounce/Theme.swift`).
///
/// The compiled-in hex values are still **hand-copied** from
/// `nebelung/palette/*.hex.json`; trill builds outside Nix so it can't consume
/// nebelung's generated `palette` output. A palette change in nebelung must be
/// mirrored here by hand — or, without a rebuild, shadowed by a runtime file of
/// the same name (see `loaded(_:)`), which is how the rice keeps an
/// already-installed trill current.
struct RicePalette {
    let name: String

    let crust, mantle, base: Color
    let surface0, surface1, surface2: Color
    let overlay0, overlay1: Color
    let text, subtext1, subtext0: Color

    let mauve, blue, lavender, sapphire, sky, teal: Color
    let green, yellow, peach, maroon, red, pink: Color

    /// Is this a LIGHT palette? Relative luminance of `base`, the window fill.
    /// Precomputed rather than derived per read: polarity decides
    /// `preferredColorScheme` and every shadow, all read inside view bodies.
    let isLight: Bool

    /// The roles trill paints with — the keys a palette file must carry.
    /// A subset of the catppuccin names: nebelung's `overlay2`, `rosewater`,
    /// and `flamingo` are intentionally unused here.
    static let roles = [
        "crust", "mantle", "base", "surface0", "surface1", "surface2",
        "overlay0", "overlay1", "text", "subtext1", "subtext0",
        "mauve", "blue", "lavender", "sapphire", "sky", "teal",
        "green", "yellow", "peach", "maroon", "red", "pink",
    ]

    /// Build a palette from a flat `role → hex` map — the shape of both the
    /// compiled-in tables below and nebelung's `*.hex.json` files. Fails (so the
    /// caller can fall back) if any role is missing or unparseable, which is
    /// also what makes a truncated or hand-mangled theme file harmless.
    init?(name: String, hex map: [String: String]) {
        var rgb: [String: (Double, Double, Double)] = [:]
        for role in Self.roles {
            guard let raw = map[role], let components = Self.components(raw) else { return nil }
            rgb[role] = components
        }
        func color(_ role: String) -> Color {
            let (r, g, b) = rgb[role]!
            return Color(.sRGB, red: r, green: g, blue: b)
        }

        self.name = name
        crust = color("crust")
        mantle = color("mantle")
        base = color("base")
        surface0 = color("surface0")
        surface1 = color("surface1")
        surface2 = color("surface2")
        overlay0 = color("overlay0")
        overlay1 = color("overlay1")
        text = color("text")
        subtext1 = color("subtext1")
        subtext0 = color("subtext0")
        mauve = color("mauve")
        blue = color("blue")
        lavender = color("lavender")
        sapphire = color("sapphire")
        sky = color("sky")
        teal = color("teal")
        green = color("green")
        yellow = color("yellow")
        peach = color("peach")
        maroon = color("maroon")
        red = color("red")
        pink = color("pink")

        let (r, g, b) = rgb["base"]!
        isLight = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
    }

    /// `"#d7d7d7"` / `"d7d7d7"` → components. Anything else is a malformed file.
    private static func components(_ raw: String) -> (Double, Double, Double)? {
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }

    // MARK: - Resolution

    static let defaultDarkName = "nebelung"
    static let defaultLightName = "nebelung-latte"

    /// The compiled-in variants, in the order Settings lists them.
    static let builtInNames = [
        defaultDarkName, "nebelung-high-contrast",
        defaultLightName, "nebelung-latte-high-contrast",
    ]

    /// Resolve a theme name to a palette. A **user file shadows a built-in of
    /// the same name**: `~/.config/trill/themes/nebelung.json` (what the rice
    /// installs) wins over the table below, so a nebelung palette bump reaches a
    /// trill that hasn't been rebuilt. Built-ins are the floor, not the ceiling.
    /// An unknown name or malformed file falls back to compiled-in nebelung.
    static func named(_ name: String) -> RicePalette {
        if let file = loaded(name) { return file }
        switch name {
        case "nebelung-high-contrast": return .nebelungHighContrast
        case defaultLightName: return .nebelungLatte
        case "nebelung-latte-high-contrast": return .nebelungLatteHighContrast
        default: return .nebelung
        }
    }

    /// `~/.config/trill/themes/` — where runtime palettes live.
    static var themesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trill/themes", isDirectory: true)
    }

    /// A runtime palette: `~/.config/trill/themes/<name>.json`, a flat
    /// catppuccin-style `role → "#hex"` map — i.e. nebelung's `*.hex.json`
    /// files verbatim, so any nebelung variant or stock Catppuccin flavor drops
    /// in without a rebuild. Read when the theme is applied (launch, or a
    /// Settings change), never per frame.
    static func loaded(_ name: String) -> RicePalette? {
        // Refuse anything that could walk out of the themes directory; the name
        // reaches us from a config file and a settings string, not a file picker.
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/") else { return nil }
        let url = themesDirectory.appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return RicePalette(name: name, hex: map)
    }

    /// Every theme a user can pick: the compiled-in variants plus whatever JSON
    /// sits in `~/.config/trill/themes/`, deduped (a file shadowing a built-in
    /// is one entry, not two).
    static func availableNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: themesDirectory, includingPropertiesForKeys: nil
        )) ?? []
        let onDisk = files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
        return builtInNames + onDisk.filter { !builtInNames.contains($0) }.sorted()
    }
}

// MARK: - Compiled-in nebelung variants

// Hand-copied from `nebelung/palette/<variant>.hex.json`. Keep the key order and
// the values verbatim so a diff against nebelung stays a one-glance check.
extension RicePalette {
    static let nebelung = RicePalette(name: "nebelung", hex: [
        "text": "d7d7d7",
        "subtext1": "c3c3c3",
        "subtext0": "aeaeae",
        "overlay1": "858585",
        "overlay0": "717171",
        "surface2": "5c5c5c",
        "surface1": "494949",
        "surface0": "343434",
        "base": "202020",
        "mantle": "191919",
        "crust": "121212",
        "pink": "f2c4e5",
        "mauve": "c9a8f1",
        "red": "ed8fa9",
        "maroon": "e6a3ad",
        "peach": "f5b58e",
        "yellow": "f7e2b5",
        "green": "abe1a6",
        "teal": "9be0d5",
        "sky": "91dbe8",
        "sapphire": "7dc6e7",
        "blue": "8db4f3",
        "lavender": "b5bff8",
    ])!

    static let nebelungHighContrast = RicePalette(name: "nebelung-high-contrast", hex: [
        "text": "ffffff",
        "subtext1": "e3e3e3",
        "subtext0": "c6c6c6",
        "overlay1": "8e8e8e",
        "overlay0": "737373",
        "surface2": "575757",
        "surface1": "3d3d3d",
        "surface0": "222222",
        "base": "090909",
        "mantle": "040404",
        "crust": "010101",
        "pink": "f2c4e5",
        "mauve": "c9a8f1",
        "red": "ed8fa9",
        "maroon": "e6a3ad",
        "peach": "f5b58e",
        "yellow": "f7e2b5",
        "green": "abe1a6",
        "teal": "9be0d5",
        "sky": "91dbe8",
        "sapphire": "7dc6e7",
        "blue": "8db4f3",
        "lavender": "b5bff8",
    ])!

    static let nebelungLatte = RicePalette(name: "nebelung-latte", hex: [
        "text": "515151",
        "subtext1": "616161",
        "subtext0": "717171",
        "overlay1": "909090",
        "overlay0": "a1a1a1",
        "surface2": "b0b0b0",
        "surface1": "c0c0c0",
        "surface0": "d0d0d0",
        "base": "f1f1f1",
        "mantle": "e9e9e9",
        "crust": "e0e0e0",
        "pink": "e47cc7",
        "mauve": "8545e3",
        "red": "ca2a40",
        "maroon": "de5059",
        "peach": "f66d2d",
        "yellow": "d99137",
        "green": "4a9e3a",
        "teal": "2f9197",
        "sky": "30a4de",
        "sapphire": "379eb1",
        "blue": "2a6ae8",
        "lavender": "7589f3",
    ])!

    static let nebelungLatteHighContrast = RicePalette(name: "nebelung-latte-high-contrast", hex: [
        "text": "434343",
        "subtext1": "555555",
        "subtext0": "686868",
        "overlay1": "8d8d8d",
        "overlay0": "a1a1a1",
        "surface2": "b4b4b4",
        "surface1": "c7c7c7",
        "surface0": "dadada",
        "base": "ffffff",
        "mantle": "f9f9f9",
        "crust": "eeeeee",
        "pink": "e47cc7",
        "mauve": "8545e3",
        "red": "ca2a40",
        "maroon": "de5059",
        "peach": "f66d2d",
        "yellow": "d99137",
        "green": "4a9e3a",
        "teal": "2f9197",
        "sky": "30a4de",
        "sapphire": "379eb1",
        "blue": "2a6ae8",
        "lavender": "7589f3",
    ])!
}

// MARK: - Which palette applies

/// How the active theme tracks macOS. `system` follows the OS light/dark switch
/// (the rice's own light/dark follow, seen from inside the app); the other two
/// pin one polarity.
enum RiceAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    /// Short enough that three chips fit one row of the 420pt settings pane.
    var title: String {
        switch self {
        case .system: "Follow macOS"
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

/// Machine-managed theme defaults from `~/.config/trill/config.json`:
///
/// ```json
/// { "themeDark": "nebelung-high-contrast",
///   "themeLight": "nebelung-latte-high-contrast" }
/// ```
///
/// The rice writes this (nebelhaus `modules/trill`) so `nebelhaus.theme.flavor`
/// and `.contrast` reach trill declaratively — trill's own settings live in
/// `UserDefaults`, which Nix has no business writing. A theme picked in Settings
/// always wins over it; delete the file (or the rice's `theme` option) and the
/// compiled-in nebelung pair applies.
struct RiceThemeDefaults: Decodable {
    let themeDark: String?
    let themeLight: String?

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/trill/config.json")
    }

    static func load() -> RiceThemeDefaults? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RiceThemeDefaults.self, from: data)
    }
}

/// Resolves the four inputs — appearance preference, the user's dark/light theme
/// picks, the rice's config.json defaults, and the compiled-in floor — into one
/// theme name. Precedence: **Settings pick › config.json › built-in nebelung**,
/// with the appearance preference choosing which of the dark/light pair applies.
enum RiceThemeResolver {
    /// Is macOS itself in Light Mode? `NSApp.appearance` is nil unless something
    /// forced an app-wide appearance — SwiftUI's `preferredColorScheme` applies
    /// to the window, not the app — so while it's nil `effectiveAppearance` is
    /// the system setting and not an echo of the polarity we just asked for. The
    /// OS-wide default is the fallback for the launch path, before there's an
    /// `NSApplication` at all.
    static var systemIsLight: Bool {
        if let app = NSApp, app.appearance == nil {
            return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .darkAqua
        }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") != "Dark"
    }

    /// Posted by macOS when the light/dark switch flips.
    static let systemAppearanceChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    static func resolve(
        appearance: RiceAppearance,
        darkPick: String,
        lightPick: String,
        defaults: RiceThemeDefaults? = RiceThemeDefaults.load(),
        systemIsLight: Bool = RiceThemeResolver.systemIsLight
    ) -> String {
        let light = switch appearance {
        case .system: systemIsLight
        case .light: true
        case .dark: false
        }
        let pick = light ? lightPick : darkPick
        if !pick.isEmpty { return pick }
        if let managed = light ? defaults?.themeLight : defaults?.themeDark, !managed.isEmpty {
            return managed
        }
        return light ? RicePalette.defaultLightName : RicePalette.defaultDarkName
    }
}
