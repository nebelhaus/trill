import XCTest
@testable import Trill

final class ServiceIdentityTests: XCTestCase {
    /// The one case where a persisted key changed: `MessageServiceKind`'s raw
    /// values are `iMessage` (capital M) / `sms` / `rcs`, the new keys are all
    /// lowercase. An existing hidden-service filter must survive the upgrade —
    /// this list lives in `UserDefaults`, so nothing else migrates it.
    func testHiddenServiceFilterMigratesFromLegacyRawValues() {
        let migrated = ServiceIdentity.migratedHiddenServices(csv: "iMessage,sms")

        XCTAssertEqual(migrated, [ServiceIdentity.iMessage.key, ServiceIdentity.sms.key])
    }

    func testMigrationIsIdempotent() {
        let once = ServiceIdentity.migratedHiddenServices(csv: "iMessage,rcs")
        let twice = ServiceIdentity.migratedHiddenServices(csv: once.sorted().joined(separator: ","))

        XCTAssertEqual(once, twice)
    }

    /// `.unknown` was never togglable and must not become hideable via a stale
    /// stored value — a thread we couldn't classify can't be allowed to vanish
    /// behind a filter that isn't in the menu.
    func testUnknownIsNeverCarriedIntoTheHiddenSet() {
        XCTAssertTrue(ServiceIdentity.migratedHiddenServices(csv: "unknown").isEmpty)
        XCTAssertFalse(ServiceIdentity.unknown.isTogglable)
    }

    func testDynamicKeysPassThroughUntouched() {
        let migrated = ServiceIdentity.migratedHiddenServices(csv: "whatsapp,signal:account-2")

        XCTAssertEqual(migrated, ["whatsapp", "signal:account-2"])
    }

    /// Two accounts on one network are distinct filterable identities that share
    /// a network family (and therefore a chip color).
    func testAccountsOnOneNetworkAreDistinctButShareTheNetwork() {
        let first = ServiceIdentity(network: "signal", displayName: "Signal", accountID: "acct-1")
        let second = ServiceIdentity(network: "signal", displayName: "Signal (work)", accountID: "acct-2")
        let single = ServiceIdentity(network: "whatsapp", displayName: "WhatsApp", accountID: nil)

        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(first.networkKey, second.networkKey)
        XCTAssertEqual(single.key, "whatsapp", "a single-account network keeps the bare network key")
    }

    func testWellKnownServicesKeepTheirLabels() {
        XCTAssertEqual(ServiceIdentity.iMessage.displayLabel, "iMessage")
        XCTAssertEqual(ServiceIdentity.sms.displayLabel, "SMS")
        XCTAssertEqual(ServiceIdentity.rcs.displayLabel, "RCS")
        XCTAssertEqual(ServiceIdentity.unknown.displayLabel, "Chat")
    }
}
