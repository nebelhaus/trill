import XCTest
@testable import Trill

/// Covers the advanced search operators: the pure `SearchQueryParser` and the
/// end-to-end narrowing through `FixtureProvider.search`, mirroring the
/// `NeedsReplyTests` template (assertions over the standard fixtures).
final class AdvancedSearchTests: XCTestCase {
    private let groupID = ConversationID(provider: ProviderID(rawValue: "fixture"), externalGUID: "fixture-group-weekend")
    private let smsID = ConversationID(provider: ProviderID(rawValue: "fixture"), externalGUID: "fixture-direct-sms")
    private let directID = ConversationID(provider: ProviderID(rawValue: "fixture"), externalGUID: "fixture-direct-imessage")

    private func search(_ raw: String, limit: Int = 200) async throws -> [Message] {
        try await FixtureProvider().search(MessageSearchQuery(raw: raw, limit: limit)).messages
    }

    // MARK: - Parser

    func testParserSplitsOperatorsFromFreeText() {
        let parsed = SearchQueryParser.parse("weekend from:avery in:group has:image plans")
        XCTAssertEqual(parsed.text, "weekend plans")
        XCTAssertEqual(parsed.filters.sender, "avery")
        XCTAssertEqual(parsed.filters.conversationKind, .group)
        XCTAssertTrue(parsed.filters.requiresImage)
        XCTAssertFalse(parsed.filters.isEmpty)
    }

    func testParserKeepsUnknownOperatorsAsFreeText() {
        let parsed = SearchQueryParser.parse("foo:bar hello")
        XCTAssertEqual(parsed.text, "foo:bar hello")
        XCTAssertTrue(parsed.filters.isEmpty)
    }

    func testParserDropsRecognizedOperatorWithBadValue() {
        let parsed = SearchQueryParser.parse("before:soon report")
        XCTAssertEqual(parsed.text, "report")
        XCTAssertNil(parsed.filters.before)
    }

    func testParserHonorsQuotedValues() {
        let parsed = SearchQueryParser.parse("from:\"Avery Chen\" lunch")
        XCTAssertEqual(parsed.filters.sender, "Avery Chen")
        XCTAssertEqual(parsed.text, "lunch")
    }

    func testEmptyQueryReturnsNothing() async throws {
        let results = try await search("   ")
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Operators over fixtures

    func testHasImageNarrowsToImageMessages() async throws {
        let results = try await search("has:image")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.attachments.contains(where: \.isImage) })
        // Exactly one fixture message carries an image (the direct thread), and
        // it is one I sent — so `from:` narrows correctly.
        XCTAssertTrue(results.allSatisfy(\.isOutgoing))
        let fromMe = try await search("from:me has:image")
        XCTAssertEqual(fromMe.count, results.count)
        let fromAvery = try await search("from:avery has:image")
        XCTAssertTrue(fromAvery.isEmpty)
    }

    func testHasLinkNarrowsToMessagesWithURLs() async throws {
        let results = try await search("has:link")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { SearchMatching.containsLink($0.text) })
        // The only seeded link lives in the group thread, sent by Morgan.
        XCTAssertTrue(results.allSatisfy { $0.conversationID == groupID })
        let fromMorgan = try await search("has:link from:morgan")
        XCTAssertEqual(fromMorgan.count, results.count)
    }

    func testInGroupRestrictsToGroupThreads() async throws {
        let results = try await search("in:group")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.conversationID == groupID })

        let direct = try await search("in:direct")
        XCTAssertFalse(direct.isEmpty)
        XCTAssertTrue(direct.allSatisfy { $0.conversationID != groupID })
    }

    func testFromRestrictsToSender() async throws {
        let results = try await search("from:avery")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { !$0.isOutgoing })
        XCTAssertTrue(results.allSatisfy { ($0.sender?.displayName ?? "").contains("Avery") })
    }

    func testIsUnreadExcludesReadThreadsAndOutgoing() async throws {
        let results = try await search("is:unread")
        XCTAssertFalse(results.isEmpty)
        // Riley Park (SMS) has zero unread; my own messages are never unread.
        XCTAssertTrue(results.allSatisfy { $0.conversationID != smsID })
        XCTAssertTrue(results.allSatisfy { !$0.isOutgoing })
    }

    func testDateBoundariesArePartitioned() async throws {
        // Group messages start on 2025-01-02 UTC; direct/SMS are all on day one.
        let after = try await search("after:2025-01-02")
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(after.allSatisfy { $0.conversationID == groupID })

        let before = try await search("before:2025-01-02")
        XCTAssertFalse(before.isEmpty)
        XCTAssertTrue(before.allSatisfy { $0.conversationID != groupID })

        // The two halves are disjoint and together cover every group + non-group
        // message: no message is both before and after the same boundary.
        XCTAssertTrue(Set(after.map(\.id)).isDisjoint(with: Set(before.map(\.id))))
    }

    func testFreeTextStillMatchesAlongsideOperators() async throws {
        // "confirmed" only appears in the group thread's last message.
        let results = try await search("confirmed in:group")
        XCTAssertEqual(results.map(\.text), ["All synthetic plans are confirmed."])
        let inDirect = try await search("confirmed in:direct")
        XCTAssertTrue(inDirect.isEmpty)
    }
}
