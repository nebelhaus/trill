import Foundation
import XCTest
@testable import NativeMessages

final class ShortcutCatalogTests: XCTestCase {
    private var allShortcuts: [ShortcutReference] {
        ShortcutCatalog.sections.flatMap(\.shortcuts)
    }

    func testCatalogIsNonEmptyAndSectioned() {
        XCTAssertFalse(ShortcutCatalog.sections.isEmpty)
        for section in ShortcutCatalog.sections {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.shortcuts.isEmpty, "\(section.title) has no shortcuts")
        }
    }

    func testEveryShortcutHasKeysAndLabel() {
        for shortcut in allShortcuts {
            XCTAssertFalse(shortcut.keys.isEmpty, "\(shortcut.label) has no keycaps")
            XCTAssertFalse(shortcut.label.isEmpty)
            for key in shortcut.keys {
                XCTAssertFalse(key.isEmpty, "\(shortcut.label) has an empty keycap")
            }
        }
    }

    func testSectionTitlesAreUnique() {
        let titles = ShortcutCatalog.sections.map(\.title)
        XCTAssertEqual(titles.count, Set(titles).count, "duplicate section titles")
    }

    func testLabelsAreUnique() {
        // Labels double as `id`, so a collision would break ForEach identity.
        let labels = allShortcuts.map(\.label)
        XCTAssertEqual(labels.count, Set(labels).count, "duplicate shortcut labels")
    }

    /// The cheat-sheet must actually document its own trigger, or it fails at the
    /// one job it has: discoverability.
    func testDocumentsItsOwnShortcut() {
        XCTAssertTrue(
            allShortcuts.contains { $0.keys == ["⌘", "/"] },
            "the ⌘/ shortcut for the cheat-sheet itself is missing"
        )
    }

    /// Spot-check that the catalog stays in lockstep with a few `AppCommands`
    /// bindings — the ones most likely to silently drift.
    func testKeyAnchorsMatchAppCommands() {
        XCTAssertTrue(allShortcuts.contains { $0.keys == ["⌘", "K"] })        // command palette
        XCTAssertTrue(allShortcuts.contains { $0.keys == ["⇧", "⌘", "F"] })   // search
        XCTAssertTrue(allShortcuts.contains { $0.keys == ["⌃", "⌘", "S"] })   // toggle sidebar
    }
}
