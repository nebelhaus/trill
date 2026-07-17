import XCTest
@testable import Trill

final class PaletteRankingTests: XCTestCase {
    private func noop() {}

    private func makeActions() -> [PaletteAction] {
        [
            PaletteAction(id: "new", title: "New Message", systemImage: "", shortcut: nil, perform: noop),
            PaletteAction(id: "settings", title: "Settings…", systemImage: "", shortcut: nil, perform: noop),
            PaletteAction(id: "zoomIn", title: "Zoom In", systemImage: "", shortcut: nil, perform: noop),
        ]
    }

    func testFixtureConversationsDoNotMatchAnActionQuery() async throws {
        let provider = FixtureProvider()
        let conversations = try await provider.conversations(page: ConversationPageRequest(limit: 100)).conversations

        let items = PaletteRanking.items(query: "sett", conversations: conversations, actions: makeActions())

        // "sett" should match only the Settings action, then the search hand-off.
        let labels: [String] = items.map {
            switch $0 {
            case let .conversation(c): "conv:\(c.displayName)"
            case let .action(a): "action:\(a.title)"
            case .searchMessages: "search"
            }
        }
        XCTAssertEqual(labels, ["action:Settings…", "search"], "unexpected items: \(labels)")
    }

    func testEmptyQueryShowsRecentsThenActions() async throws {
        let provider = FixtureProvider()
        let conversations = try await provider.conversations(page: ConversationPageRequest(limit: 100)).conversations

        let items = PaletteRanking.items(query: "", conversations: conversations, actions: makeActions())
        let conversationCount = items.filter { if case .conversation = $0 { return true } else { return false } }.count
        let actionCount = items.filter { if case .action = $0 { return true } else { return false } }.count

        XCTAssertEqual(conversationCount, conversations.count)
        XCTAssertEqual(actionCount, 3)
        XCTAssertFalse(items.contains { if case .searchMessages = $0 { return true } else { return false } })
    }
}
