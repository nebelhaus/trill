import Foundation
import XCTest
@testable import Trill

/// Browser-style ⌘[ / ⌘] history over the selected conversation. Exercises the
/// stacks directly through `select`/`goBack`/`goForward` — no provider load
/// needed, since `select` records history off the ID regardless of list state.
@MainActor
final class InboxNavigationHistoryTests: XCTestCase {
    private func makeModel() throws -> InboxModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrillTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        return InboxModel(database: database, snippets: SnippetStore(database: database))
    }

    private func id(_ guid: String) -> ConversationID {
        ConversationID(provider: ProviderID(rawValue: "fixture"), externalGUID: guid)
    }

    func testBackAndForwardWalkTheTrail() throws {
        let model = try makeModel()
        let a = id("a"), b = id("b"), c = id("c")

        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)

        model.select(a)   // first selection seeds nothing to go back to
        XCTAssertFalse(model.canGoBack)

        model.select(b)
        model.select(c)
        XCTAssertTrue(model.canGoBack)
        XCTAssertFalse(model.canGoForward)

        model.goBack()    // c -> b
        XCTAssertEqual(model.selectedConversationID, b)
        XCTAssertTrue(model.canGoForward)

        model.goBack()    // b -> a
        XCTAssertEqual(model.selectedConversationID, a)
        XCTAssertFalse(model.canGoBack)

        model.goForward() // a -> b
        XCTAssertEqual(model.selectedConversationID, b)

        model.goForward() // b -> c
        XCTAssertEqual(model.selectedConversationID, c)
        XCTAssertFalse(model.canGoForward)
    }

    func testFreshSelectionForksAndClearsForward() throws {
        let model = try makeModel()
        let a = id("a"), b = id("b"), c = id("c")

        model.select(a)
        model.select(b)
        model.goBack()     // back on a, forward = [b]
        XCTAssertTrue(model.canGoForward)

        model.select(c)    // a fresh pick discards the forward trail
        XCTAssertFalse(model.canGoForward)
        XCTAssertTrue(model.canGoBack)

        model.goBack()     // c -> a
        XCTAssertEqual(model.selectedConversationID, a)
    }

    func testReselectingSameThreadDoesNotRecordHistory() throws {
        let model = try makeModel()
        let a = id("a")

        model.select(a)
        model.select(a)
        XCTAssertFalse(model.canGoBack)
    }

    func testEmptyStacksAreNoOps() throws {
        let model = try makeModel()
        model.goBack()
        model.goForward()
        XCTAssertNil(model.selectedConversationID)
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.canGoForward)
    }
}
