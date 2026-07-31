import XCTest
@testable import Trill

final class UpdateCheckTests: XCTestCase {

    func testInstallKindDetection() {
        let home = "/Users/testuser"

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/nix/store/abc1234-trill-2026.07.31/Applications/Trill.app", home: home),
            .nix
        )

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/Users/testuser/.local/state/trill/Trill.app", home: home),
            .rice
        )

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/opt/homebrew/Caskroom/trill/2026.07.31/Trill.app", home: home),
            .homebrew
        )

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/usr/local/Caskroom/trill/2026.07.31/Trill.app", home: home),
            .homebrew
        )

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/Applications/Trill.app", home: home),
            .direct
        )

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/Users/testuser/Applications/Trill.app", home: home),
            .direct
        )

        XCTAssertEqual(
            InstallKind.detect(bundlePath: "/tmp/custom/Trill.app", home: home),
            .unknown
        )
    }

    func testInstallKindCapabilitiesAndHints() {
        XCTAssertTrue(InstallKind.direct.canSelfUpdate)
        XCTAssertTrue(InstallKind.homebrew.canSelfUpdate)
        XCTAssertFalse(InstallKind.rice.canSelfUpdate)
        XCTAssertFalse(InstallKind.nix.canSelfUpdate)

        XCTAssertTrue(InstallKind.rice.actionHint.contains("haus update"))
        XCTAssertTrue(InstallKind.nix.actionHint.contains("trill flake input"))
        XCTAssertTrue(InstallKind.homebrew.actionHint.contains("Homebrew"))
        XCTAssertTrue(InstallKind.direct.actionHint.contains("Trill"))
    }

    func testIsNewerCalVerComparison() {
        // Newer dates
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31", than: "2026.07.30"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.08.01", than: "2026.07.31"))

        // Same date, older or equal
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.30", than: "2026.07.30"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.29", than: "2026.07.30"))

        // Same date, repeat suffixes (-1, -2, -10)
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-2", than: "2026.07.31-1"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-10", than: "2026.07.31-2"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31-2"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31-1"))

        // Dev build running never claims updates in background
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31", than: "dev"))
    }

    func testShouldPinAndDismissalExpiration() {
        // Available version without dismissal pins
        XCTAssertTrue(UpdateCheck.shouldPin(available: "2026.07.31", dismissed: nil))

        // Same version dismissed stops pinning
        XCTAssertFalse(UpdateCheck.shouldPin(available: "2026.07.31", dismissed: "2026.07.31"))

        // Newer version landing un-dismisses / pins again
        XCTAssertTrue(UpdateCheck.shouldPin(available: "2026.08.01", dismissed: "2026.07.31"))

        // Nil available version never pins
        XCTAssertFalse(UpdateCheck.shouldPin(available: nil, dismissed: "2026.07.31"))
    }
}
