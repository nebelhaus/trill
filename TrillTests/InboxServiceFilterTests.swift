import Foundation
import XCTest
@testable import Trill

/// Phase 1 is a refactor: in fixture mode nothing about the service filter may
/// look or behave differently than it did with the closed `MessageServiceKind`
/// enum. These pin that, and pin the new dynamic behavior alongside it.
///
/// The one case that needs a populated conversation list lives in
/// `InboxModelTabsTests`, which already loads one.
@MainActor
final class InboxServiceFilterTests: XCTestCase {
    private var suiteName = "TrillTests.services"
    private var defaults = UserDefaults(suiteName: "TrillTests.services")!

    override func setUp() {
        super.setUp()
        suiteName = "TrillTests.services-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeModel() throws -> InboxModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrillTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        return InboxModel(database: database, snippets: SnippetStore(database: database), defaults: defaults)
    }

    /// The old menu was the fixed `MessageServiceKind.togglable`. Deriving it
    /// purely from what's loaded would silently drop RCS wherever no RCS thread
    /// exists yet — a visible difference, and therefore a bug.
    func testNativeServicesAreAlwaysOfferedInTheirOldOrder() throws {
        let model = try makeModel()

        XCTAssertEqual(model.availableServices.map(\.displayLabel), ["iMessage", "SMS", "RCS"])
    }

    func testUnknownIsNeverOfferedInTheMenu() throws {
        let model = try makeModel()

        XCTAssertFalse(model.availableServices.contains { $0.isUnknown })
    }

    /// A network that isn't one of the natives is a first-class filter entry, and
    /// two accounts on it filter independently.
    func testDynamicNetworksAndAccountsAreDistinctEntries() throws {
        let model = try makeModel()
        let work = ServiceIdentity(network: "signal", displayName: "Signal (work)", accountID: "acct-2")
        let personal = ServiceIdentity(network: "signal", displayName: "Signal", accountID: "acct-1")

        model.toggleService(work)

        XCTAssertFalse(model.showsService(work))
        XCTAssertTrue(
            model.showsService(personal),
            "hiding one account must not hide the other on the same network"
        )
        XCTAssertTrue(
            model.availableServices.contains { $0.key == work.key },
            "a hidden service stays listed so its filter can be switched back off"
        )
    }

    func testHiddenServicesPersistAsMigratableKeys() throws {
        let model = try makeModel()
        model.toggleService(.sms)

        let stored = try XCTUnwrap(defaults.string(forKey: "hiddenServices"))
        XCTAssertEqual(stored, ServiceIdentity.sms.key)
        XCTAssertEqual(
            ServiceIdentity.migratedHiddenServices(csv: stored),
            [ServiceIdentity.sms.key]
        )

        model.showAllServices()
        XCTAssertEqual(defaults.string(forKey: "hiddenServices"), "")
    }
}
