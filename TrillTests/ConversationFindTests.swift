import XCTest
@testable import Trill

final class ConversationFindTests: XCTestCase {
    private let conversationID = ConversationID(
        provider: ProviderID(rawValue: "fixture"),
        externalGUID: "find-thread"
    )

    private func message(_ id: String, text: String, at offset: TimeInterval) -> Message {
        Message(
            id: MessageID(provider: ProviderID(rawValue: "fixture"), externalGUID: id),
            conversationID: conversationID,
            providerSequence: id,
            sender: nil,
            isOutgoing: false,
            text: text,
            createdAt: Date(timeIntervalSinceReferenceDate: offset),
            sentAt: nil,
            deliveredAt: nil,
            attachments: [],
            reactions: [],
            replyTo: nil,
            threadOrigin: nil,
            service: .iMessage,
            deliveryState: .delivered
        )
    }

    private func thread() -> [Message] {
        [
            message("m0", text: "Let's grab coffee tomorrow", at: 0),
            message("m1", text: "Sounds good, morning works", at: 10),
            message("m2", text: "Coffee at the usual place?", at: 20),
            message("m3", text: "", at: 30),                        // attachment-only
            message("m4", text: "Yeah the COFFEE cart on 5th", at: 40),
        ]
    }

    // MARK: - Pure matcher

    func testMatchIsCaseInsensitiveSubstringInChronologicalOrder() {
        let ids = ConversationModel.matchingMessageIDs(in: thread(), query: "coffee")
        XCTAssertEqual(ids.map(\.externalGUID), ["m0", "m2", "m4"])
    }

    func testBlankQueryMatchesNothing() {
        XCTAssertTrue(ConversationModel.matchingMessageIDs(in: thread(), query: "   ").isEmpty)
    }

    func testQueryIsTrimmedBeforeMatching() {
        let ids = ConversationModel.matchingMessageIDs(in: thread(), query: "  morning  ")
        XCTAssertEqual(ids.map(\.externalGUID), ["m1"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(ConversationModel.matchingMessageIDs(in: thread(), query: "zzz").isEmpty)
    }

    // MARK: - Model navigation

    @MainActor
    private func loadedModel() async throws -> ConversationModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrillTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase(url: root.appendingPathComponent("app.sqlite3"))
        let repository = MessagesRepository(provider: FixtureProvider(), database: database)
        let model = ConversationModel(repository: repository)

        let conversations = try await FixtureProvider()
            .conversations(page: ConversationPageRequest(limit: 100)).conversations
        let conversation = try XCTUnwrap(conversations.first)
        model.select(conversation)
        try await waitUntilLoaded(model)
        return model
    }

    @MainActor
    private func waitUntilLoaded(_ model: ConversationModel) async throws {
        for _ in 0..<200 where model.state != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state, .loaded)
        XCTAssertFalse(model.messages.isEmpty)
    }

    @MainActor
    func testBeginFindOverEmptyQueryHasNoMatches() async throws {
        let model = try await loadedModel()
        model.beginFind()
        XCTAssertTrue(model.isFindPresented)
        XCTAssertTrue(model.findMatches.isEmpty)
        XCTAssertNil(model.currentFindMatchID)
    }

    @MainActor
    func testTypingQuerySelectsNewestMatchAndReveals() async throws {
        let model = try await loadedModel()
        model.beginFind()
        // A single common letter is present in most fixture messages.
        model.findQuery = "e"

        let expected = ConversationModel.matchingMessageIDs(in: model.messages, query: "e")
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(model.findMatches, expected)
        XCTAssertEqual(model.findMatchSet, Set(expected))
        // Caret lands on the newest (last) match, nearest where the reader is.
        XCTAssertEqual(model.findCurrentIndex, expected.count - 1)
        XCTAssertEqual(model.currentFindMatchID, expected.last)
        // The newest match was pushed to the view to scroll to.
        XCTAssertEqual(model.revealTarget, expected.last)
    }

    @MainActor
    func testNextAndPreviousWrapAround() async throws {
        let model = try await loadedModel()
        model.beginFind()
        model.findQuery = "e"
        let count = model.findMatches.count
        try XCTSkipUnless(count > 1, "Need multiple matches to exercise wrap-around")

        XCTAssertEqual(model.findCurrentIndex, count - 1)
        model.findNext()                                  // wraps past the end
        XCTAssertEqual(model.findCurrentIndex, 0)
        XCTAssertEqual(model.currentFindMatchID, model.findMatches.first)

        model.findPrevious()                              // wraps back to the end
        XCTAssertEqual(model.findCurrentIndex, count - 1)
        XCTAssertEqual(model.currentFindMatchID, model.findMatches.last)
    }

    @MainActor
    func testEndFindClearsAllState() async throws {
        let model = try await loadedModel()
        model.beginFind()
        model.findQuery = "e"
        XCTAssertFalse(model.findMatches.isEmpty)

        model.endFind()
        XCTAssertFalse(model.isFindPresented)
        XCTAssertEqual(model.findQuery, "")
        XCTAssertTrue(model.findMatches.isEmpty)
        XCTAssertTrue(model.findMatchSet.isEmpty)
        XCTAssertNil(model.currentFindMatchID)
    }

    @MainActor
    func testSelectingAnotherConversationResetsFind() async throws {
        let model = try await loadedModel()
        model.beginFind()
        model.findQuery = "e"
        XCTAssertTrue(model.isFindPresented)

        let conversations = try await FixtureProvider()
            .conversations(page: ConversationPageRequest(limit: 100)).conversations
        let other = try XCTUnwrap(conversations.dropFirst().first)
        model.select(other)

        XCTAssertFalse(model.isFindPresented)
        XCTAssertEqual(model.findQuery, "")
        XCTAssertTrue(model.findMatches.isEmpty)
    }
}
