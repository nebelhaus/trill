import Foundation
import XCTest
@testable import Trill

/// The in-app conversation tab strip's model logic: the browser open/replace/
/// switch/close semantics on `InboxModel.openTabs`, plus persistence restore.
/// Drives the deterministic fixture provider so tabs (which only form for loaded
/// threads) have a real conversation list to work against.
@MainActor
final class InboxModelTabsTests: XCTestCase {
    private let provider = ProviderID(rawValue: "fixture")
    private var a: ConversationID { ConversationID(provider: provider, externalGUID: "fixture-direct-imessage") }
    private var b: ConversationID { ConversationID(provider: provider, externalGUID: "fixture-direct-sms") }
    private var c: ConversationID { ConversationID(provider: provider, externalGUID: "fixture-group-weekend") }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "openTabs")
        UserDefaults.standard.removeObject(forKey: "activeTab")
        UserDefaults.standard.removeObject(forKey: "providerMode")
        super.tearDown()
    }

    /// A model whose fixture conversations have finished loading. `clearTabs`
    /// wipes any persisted tab state first (the default) so a test starts clean;
    /// the persistence test seeds those keys itself and opts out.
    private func makeLoadedModel(clearTabs: Bool = true) async throws -> InboxModel {
        if clearTabs {
            UserDefaults.standard.removeObject(forKey: "openTabs")
            UserDefaults.standard.removeObject(forKey: "activeTab")
        }
        UserDefaults.standard.set("fixture", forKey: "providerMode")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrillTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        let model = InboxModel(database: database, snippets: SnippetStore(database: database))
        model.load()
        for _ in 0..<300 {
            if model.state == .loaded { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state, .loaded, "fixture conversations should load")
        return model
    }

    func testOpenInNewTabAppendsAndActivates() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        XCTAssertEqual(model.openTabs, [a])

        model.openInNewTab(b)
        XCTAssertEqual(model.openTabs, [a, b])
        XCTAssertEqual(model.selectedConversationID, b)

        // Re-opening an already-open thread just activates it, no duplicate tab.
        model.openInNewTab(a)
        XCTAssertEqual(model.openTabs, [a, b])
        XCTAssertEqual(model.selectedConversationID, a)
    }

    func testSelectReplacesActiveTabInPlace() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        XCTAssertEqual(model.openTabs, [a])

        // A plain sidebar select navigates the active tab in place — no growth.
        model.select(b)
        XCTAssertEqual(model.openTabs, [b])
        XCTAssertEqual(model.selectedConversationID, b)

        // Only an explicit new-tab open grows the strip.
        model.openInNewTab(c)
        XCTAssertEqual(model.openTabs, [b, c])
    }

    func testEachTabKeepsItsOwnWarmModel() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        model.openInNewTab(b)

        // Switching tabs re-points `conversationModel` to that tab's warm model,
        // whose `conversation` is set synchronously by `select` — no reload.
        model.activateTab(a)
        XCTAssertEqual(model.conversationModel.conversation?.id, a)
        model.activateTab(b)
        XCTAssertEqual(model.conversationModel.conversation?.id, b)
    }

    func testCloseActiveTabLandsOnNeighbor() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        model.openInNewTab(b)
        model.openInNewTab(c)          // tabs [a,b,c], active c

        model.closeTab(c)              // active was last → fall back to new last
        XCTAssertEqual(model.openTabs, [a, b])
        XCTAssertEqual(model.selectedConversationID, b)

        model.activateTab(a)
        model.closeTab(b)              // closing an inactive tab keeps the active one
        XCTAssertEqual(model.openTabs, [a])
        XCTAssertEqual(model.selectedConversationID, a)

        model.closeTab(a)              // closing the last tab deselects
        XCTAssertEqual(model.openTabs, [])
        XCTAssertNil(model.selectedConversationID)
    }

    func testCloseActiveMiddleTabSlidesToNext() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        model.openInNewTab(b)
        model.openInNewTab(c)
        model.activateTab(b)           // active is the middle tab

        model.closeTab(b)              // the tab sliding into b's slot (c) takes over
        XCTAssertEqual(model.openTabs, [a, c])
        XCTAssertEqual(model.selectedConversationID, c)
    }

    func testNextAndPreviousTabCycle() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        model.openInNewTab(b)
        model.openInNewTab(c)          // active c

        model.nextTab()                // wraps c -> a
        XCTAssertEqual(model.selectedConversationID, a)
        model.previousTab()            // a -> c
        XCTAssertEqual(model.selectedConversationID, c)
        model.previousTab()            // c -> b
        XCTAssertEqual(model.selectedConversationID, b)
    }

    func testMoveTabReordersInBothDirections() async throws {
        let model = try await makeLoadedModel()

        model.select(a)
        model.openInNewTab(b)
        model.openInNewTab(c)          // [a, b, c]

        model.moveTab(a, to: c)        // drag a rightward onto c
        XCTAssertEqual(model.openTabs, [b, c, a])

        model.moveTab(a, to: b)        // drag a back leftward onto b
        XCTAssertEqual(model.openTabs, [a, b, c])

        // Reordering never disturbs which tab is active.
        XCTAssertEqual(model.selectedConversationID, c)
    }

    func testPersistedTabsRestoreAndDropStaleEntries() async throws {
        // Seed one real thread and one that no longer exists; only the real one
        // should come back, and the persisted active tab should win.
        let bogus = ConversationID(provider: provider, externalGUID: "fixture-gone")
        UserDefaults.standard.set([a.persistenceKey, bogus.persistenceKey, b.persistenceKey], forKey: "openTabs")
        UserDefaults.standard.set(b.persistenceKey, forKey: "activeTab")

        let model = try await makeLoadedModel(clearTabs: false)

        XCTAssertEqual(model.openTabs, [a, b])   // bogus filtered out, order preserved
        XCTAssertEqual(model.selectedConversationID, b)
    }
}
