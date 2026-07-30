import XCTest
@testable import Trill

/// The palette is now data, not literals: it can come from a JSON file, so it can
/// also be missing, truncated, or hand-mangled. These pin the fallback chain and
/// the polarity call that light-mode chrome depends on.
final class RicePaletteTests: XCTestCase {
    private let nebelungHex = [
        "text": "d7d7d7", "subtext1": "c3c3c3", "subtext0": "aeaeae",
        "overlay1": "858585", "overlay0": "717171",
        "surface2": "5c5c5c", "surface1": "494949", "surface0": "343434",
        "base": "202020", "mantle": "191919", "crust": "121212",
        "pink": "f2c4e5", "mauve": "c9a8f1", "red": "ed8fa9", "maroon": "e6a3ad",
        "peach": "f5b58e", "yellow": "f7e2b5", "green": "abe1a6", "teal": "9be0d5",
        "sky": "91dbe8", "sapphire": "7dc6e7", "blue": "8db4f3", "lavender": "b5bff8",
    ]

    // MARK: - Parsing

    func testBuildsFromFlatHexMap() {
        let palette = RicePalette(name: "test", hex: nebelungHex)
        XCTAssertNotNil(palette)
        XCTAssertEqual(palette?.name, "test")
    }

    func testAcceptsLeadingHashHexValues() {
        var hex = nebelungHex
        for (key, value) in hex { hex[key] = "#\(value)" }
        XCTAssertNotNil(RicePalette(name: "hashed", hex: hex))
    }

    func testRejectsMissingRole() {
        var hex = nebelungHex
        hex["surface1"] = nil
        XCTAssertNil(RicePalette(name: "short", hex: hex), "a truncated palette must fail, not paint a hole")
    }

    func testRejectsMalformedHex() {
        var hex = nebelungHex
        hex["base"] = "not-a-color"
        XCTAssertNil(RicePalette(name: "bad", hex: hex))
        hex["base"] = "fff"
        XCTAssertNil(RicePalette(name: "short-hex", hex: hex))
    }

    /// nebelung's `*.hex.json` carries three roles trill doesn't paint with;
    /// extra keys are ignored so the files drop in verbatim.
    func testIgnoresUnusedNebelungRoles() {
        var hex = nebelungHex
        hex["overlay2"] = "9a9a9a"
        hex["rosewater"] = "f3e1dd"
        hex["flamingo"] = "efcece"
        XCTAssertNotNil(RicePalette(name: "full", hex: hex))
    }

    // MARK: - Polarity

    func testCompiledInVariantPolarity() {
        XCTAssertFalse(RicePalette.nebelung.isLight)
        XCTAssertFalse(RicePalette.nebelungHighContrast.isLight)
        XCTAssertTrue(RicePalette.nebelungLatte.isLight)
        XCTAssertTrue(RicePalette.nebelungLatteHighContrast.isLight)
    }

    // MARK: - Name resolution

    func testUnknownNameFallsBackToNebelung() {
        XCTAssertEqual(RicePalette.named("no-such-theme").name, "nebelung")
        XCTAssertEqual(RicePalette.named("").name, "nebelung")
    }

    func testBuiltInNamesResolveToTheirVariant() {
        for name in RicePalette.builtInNames where RicePalette.loaded(name) == nil {
            XCTAssertEqual(RicePalette.named(name).name, name)
        }
    }

    func testRejectsPathTraversalInThemeName() {
        XCTAssertNil(RicePalette.loaded("../config"))
        XCTAssertNil(RicePalette.loaded("sub/theme"))
        XCTAssertNil(RicePalette.loaded(".hidden"))
        XCTAssertNil(RicePalette.loaded(""))
    }

    func testAvailableNamesIncludesEveryBuiltInOnce() {
        let names = RicePalette.availableNames()
        for builtIn in RicePalette.builtInNames {
            XCTAssertEqual(names.filter { $0 == builtIn }.count, 1, "\(builtIn) listed more than once")
        }
    }

    // MARK: - Which palette applies

    func testSettingsPickWinsOverEverything() {
        let defaults = RiceThemeDefaults(themeDark: "rice-dark", themeLight: "rice-light")
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .dark, darkPick: "mine", lightPick: "",
                defaults: defaults, systemIsLight: false
            ),
            "mine"
        )
    }

    func testConfigFileWinsOverBuiltInFloor() {
        let defaults = RiceThemeDefaults(themeDark: "rice-dark", themeLight: "rice-light")
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .dark, darkPick: "", lightPick: "",
                defaults: defaults, systemIsLight: false
            ),
            "rice-dark"
        )
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .light, darkPick: "", lightPick: "",
                defaults: defaults, systemIsLight: false
            ),
            "rice-light"
        )
    }

    func testFallsBackToCompiledInPair() {
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .dark, darkPick: "", lightPick: "",
                defaults: nil, systemIsLight: true
            ),
            RicePalette.defaultDarkName
        )
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .light, darkPick: "", lightPick: "",
                defaults: nil, systemIsLight: false
            ),
            RicePalette.defaultLightName
        )
    }

    func testSystemAppearanceChoosesWithinThePair() {
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .system, darkPick: "d", lightPick: "l",
                defaults: nil, systemIsLight: true
            ),
            "l"
        )
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .system, darkPick: "d", lightPick: "l",
                defaults: nil, systemIsLight: false
            ),
            "d"
        )
    }

    /// An empty string in the config file is "unset", not a theme named "".
    func testEmptyManagedNameIsIgnored() {
        let defaults = RiceThemeDefaults(themeDark: "", themeLight: nil)
        XCTAssertEqual(
            RiceThemeResolver.resolve(
                appearance: .dark, darkPick: "", lightPick: "",
                defaults: defaults, systemIsLight: false
            ),
            RicePalette.defaultDarkName
        )
    }
}
