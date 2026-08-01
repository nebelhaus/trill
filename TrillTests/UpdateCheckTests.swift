import XCTest
@testable import Trill

final class UpdateCheckTests: XCTestCase {

    // MARK: - Cohort detection
    //
    // The trap these pin: the rice (modules/trill, postActivation) and a
    // Homebrew cask BOTH end up at /Applications/Trill.app, so the path alone
    // can't tell them apart from a drag-install. The receipts do.

    func testNixStorePathIsNix() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/nix/store/abc123-trill-2026.07.31/Applications/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: false
            ),
            .nix
        )
    }

    func testRiceMarkerWinsOverTheSharedApplicationsPath() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: true,
                hasCaskReceipt: false
            ),
            .rice
        )
    }

    /// A machine that has been both keeps taking updates from the rice: its
    /// activation script reinstalls the bundle on every rebuild.
    func testRiceMarkerOutranksALeftoverCaskReceipt() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: true,
                hasCaskReceipt: true
            ),
            .rice
        )
    }

    func testCaskReceiptMakesApplicationsAHomebrewInstall() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Applications/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: true
            ),
            .homebrew
        )
    }

    func testApplicationsWithoutAnyReceiptIsADragInstall() {
        for path in ["/Applications/Trill.app", "/Users/testuser/Applications/Trill.app"] {
            XCTAssertEqual(
                InstallKind.detect(
                    bundlePath: path,
                    home: "/Users/testuser",
                    hasRiceMarker: false,
                    hasCaskReceipt: false
                ),
                .direct,
                path
            )
        }
    }

    /// A marker is only the rice's when the bundle sits where the rice puts it.
    func testUserApplicationsIsNotClaimedByTheRiceMarker() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Users/testuser/Applications/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: true,
                hasCaskReceipt: false
            ),
            .direct
        )
    }

    func testCaskroomAndRiceStatePathsStillResolve() {
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/opt/homebrew/Caskroom/trill/2026.07.31/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: true
            ),
            .homebrew
        )
        XCTAssertEqual(
            InstallKind.detect(
                bundlePath: "/Users/testuser/.local/state/trill/Trill.app",
                home: "/Users/testuser",
                hasRiceMarker: false,
                hasCaskReceipt: false
            ),
            .rice
        )
    }

    /// A build running out of DerivedData is nobody's install: it must not be
    /// offered a self-swap.
    func testUnknownPathIsUnknownAndCannotSelfUpdate() {
        let kind = InstallKind.detect(
            bundlePath: "/Users/testuser/Library/Developer/Xcode/DerivedData/Trill-abc/Build/Products/Debug/Trill.app",
            home: "/Users/testuser",
            hasRiceMarker: false,
            hasCaskReceipt: false
        )
        XCTAssertEqual(kind, .unknown)
        XCTAssertFalse(kind.canSelfUpdate)
    }

    // MARK: - Cohort copy

    func testOnlyTheMutableCohortsSelfUpdate() {
        XCTAssertTrue(InstallKind.direct.canSelfUpdate)
        XCTAssertTrue(InstallKind.homebrew.canSelfUpdate)
        XCTAssertFalse(InstallKind.rice.canSelfUpdate)
        XCTAssertFalse(InstallKind.nix.canSelfUpdate)
        XCTAssertFalse(InstallKind.unknown.canSelfUpdate)
    }

    /// The hint is the one thing the nudge must get right: a cohort that can't
    /// self-update has to be told the command that does work for it.
    func testHintsNameEachCohortsRealNextStep() {
        XCTAssertTrue(InstallKind.rice.actionHint.contains("haus update"))
        XCTAssertTrue(InstallKind.rice.bannerHint.contains("haus update"))
        XCTAssertTrue(InstallKind.nix.actionHint.contains("flake input"))
        XCTAssertTrue(InstallKind.nix.bannerHint.contains("flake input"))
        XCTAssertTrue(InstallKind.homebrew.bannerHint.contains("brew upgrade --cask trill"))
        XCTAssertEqual(InstallKind.rice.buttonLabel, "Copy Command")
        XCTAssertEqual(InstallKind.nix.buttonLabel, "Copy Command")
        XCTAssertEqual(InstallKind.direct.buttonLabel, "Update & Restart")
        XCTAssertEqual(InstallKind.unknown.buttonLabel, "Open Releases")
    }

    // MARK: - Version ordering

    func testIsNewerCalVerComparison() {
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31", than: "2026.07.30"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.08.01", than: "2026.07.31"))

        XCTAssertFalse(UpdateCheck.isNewer("2026.07.30", than: "2026.07.30"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.29", than: "2026.07.30"))

        // Same-day repeats compare numerically — a string compare would put
        // "-10" before "-2" and silently never nudge.
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-2", than: "2026.07.31-1"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-10", than: "2026.07.31-2"))
        XCTAssertTrue(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31-2"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.07.31-1", than: "2026.07.31-1"))
    }

    /// Neither an unversioned Xcode build nor a `bench try` branch build ever
    /// gets nudged — "updating" one means throwing the branch away.
    func testDevBuildsAreNeverNewerThan() {
        XCTAssertTrue(UpdateCheck.isDevVersion("dev"))
        XCTAssertTrue(UpdateCheck.isDevVersion(""))
        XCTAssertTrue(UpdateCheck.isDevVersion("2026.07.31-dev"))
        XCTAssertFalse(UpdateCheck.isDevVersion("2026.07.31"))
        XCTAssertFalse(UpdateCheck.isDevVersion("2026.07.31-2"))

        XCTAssertFalse(UpdateCheck.isNewer("2026.08.01", than: "dev"))
        XCTAssertFalse(UpdateCheck.isNewer("2026.08.01", than: "2026.07.31-dev"))
    }

    // MARK: - Dismissal

    func testShouldPinAndDismissalExpiration() {
        XCTAssertTrue(UpdateCheck.shouldPin(available: "2026.07.31", dismissed: nil))
        XCTAssertFalse(UpdateCheck.shouldPin(available: "2026.07.31", dismissed: "2026.07.31"))
        // A dismissal must expire when a newer release lands, or "dismiss"
        // quietly becomes "never tell me again".
        XCTAssertTrue(UpdateCheck.shouldPin(available: "2026.08.01", dismissed: "2026.07.31"))
        XCTAssertFalse(UpdateCheck.shouldPin(available: nil, dismissed: "2026.07.31"))
    }

    // MARK: - Updater scripts
    //
    // These run after the app has quit, so a syntax error would be invisible:
    // no window, no log, just a Trill that never comes back. `bash -n` is the
    // cheapest way to keep Swift-side string escaping honest.

    func testUpdaterScriptsAreValidShell() throws {
        for (name, script) in [
            ("direct", UpdateCheck.directUpdateScript),
            ("homebrew", UpdateCheck.homebrewUpdateScript),
        ] {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("trill-update-\(name)-\(UUID().uuidString).sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }

            let check = Process()
            check.executableURL = URL(fileURLWithPath: "/bin/bash")
            check.arguments = ["-n", url.path]
            let errors = Pipe()
            check.standardError = errors
            try check.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            check.waitUntilExit()
            XCTAssertEqual(
                check.terminationStatus, 0,
                "\(name): \(String(data: output, encoding: .utf8) ?? "")"
            )
        }
    }

    /// The self-update takes its inputs as positional arguments; a path
    /// interpolated into the script text would be code, not data.
    func testUpdaterScriptsTakeTheirInputsAsArguments() {
        XCTAssertTrue(UpdateCheck.directUpdateScript.contains("APP=\"$1\"; TAG=\"$2\"; PID=\"$3\""))
        XCTAssertTrue(UpdateCheck.homebrewUpdateScript.contains("APP=\"$1\"; PID=\"$2\""))
        for script in [UpdateCheck.directUpdateScript, UpdateCheck.homebrewUpdateScript] {
            // pkill -f would match this very script's own command line and kill
            // the updater before it could reopen the app.
            XCTAssertFalse(script.contains("pkill"))
            // Both end by putting Trill back, whatever happened.
            XCTAssertTrue(script.contains("reopen"))
        }
        // ditto, never unzip: unpacking a `ditto -c -k --sequesterRsrc` archive
        // (what release.yml writes) any other way can break the signature.
        // Comments are stripped first — the script explains this in prose too.
        let commands = UpdateCheck.directUpdateScript
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
        XCTAssertTrue(commands.contains("/usr/bin/ditto -x -k"))
        XCTAssertFalse(commands.contains("unzip"))
    }

    // MARK: - Release URL
    //
    // The self-update downloads by convention, so the convention is pinned
    // here: release.yml publishes `trill-v<version>-macos.zip`, and the cask
    // (nebelhaus/homebrew-tap) fetches the same name.

    func testDownloadURLMatchesTheReleaseAssetName() {
        let tag = "v2026.07.31"
        XCTAssertEqual(
            "https://github.com/nebelhaus/trill/releases/download/\(tag)/trill-\(tag)-macos.zip",
            "https://github.com/nebelhaus/trill/releases/download/v2026.07.31/trill-v2026.07.31-macos.zip"
        )
        XCTAssertEqual(
            UpdateCheck.endpoint.absoluteString,
            "https://api.github.com/repos/nebelhaus/trill/releases/latest"
        )
    }
}
