import XCTest
@testable import Trill

/// Sending a message should take the reader to the bottom of the thread. The sent
/// row lands asynchronously from `chat.db` (after the send call returns), so the
/// model arms a tail-follow (`scrollToBottom`) that re-anchors the open-pin to the
/// newest row as messages arrive — without yanking a reader who's simply scrolled
/// up while someone *else*'s message lands.
final class ConversationScrollTests: XCTestCase {
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
        model.select(try XCTUnwrap(conversations.first))
        for _ in 0..<200 where model.state != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.state, .loaded)
        XCTAssertFalse(model.messages.isEmpty)
        return model
    }

    /// Builds a message newer than everything currently loaded, so it sorts to the tail.
    @MainActor
    private func trailing(_ id: String, isOutgoing: Bool, in model: ConversationModel) -> Message {
        Message(
            id: MessageID(provider: ProviderID(rawValue: "fixture"), externalGUID: id),
            conversationID: model.conversation!.id,
            providerSequence: id,
            sender: nil,
            isOutgoing: isOutgoing,
            text: "trailing \(id)",
            createdAt: Date(timeIntervalSinceNow: 3_600),
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

    @MainActor
    func testScrollToBottomPinsToNewestLoadedMessage() async throws {
        let model = try await loadedModel()
        model.consumeBottomScroll()
        let last = try XCTUnwrap(model.messages.last)
        model.scrollToBottom()
        XCTAssertEqual(model.pendingBottomScroll, last.id)
    }

    @MainActor
    func testSentRowArrivalFollowsTailToNewestRow() async throws {
        let model = try await loadedModel()
        model.consumeBottomScroll()      // drop the open-pin from load
        model.scrollToBottom()           // the send gesture
        let sent = trailing("just-sent", isOutgoing: true, in: model)
        model.appendLive(sent)
        XCTAssertEqual(model.pendingBottomScroll, sent.id)
    }

    /// The 400ms open-pin settle can fire (clearing `pendingBottomScroll`) before
    /// the sent row lands — the follow must survive it and still catch the arrival.
    @MainActor
    func testFollowSurvivesPinSettleUntilSentRowLands() async throws {
        let model = try await loadedModel()
        model.consumeBottomScroll()
        model.scrollToBottom()
        model.consumeBottomScroll()      // settle fires early
        XCTAssertNil(model.pendingBottomScroll)
        let sent = trailing("late", isOutgoing: true, in: model)
        model.appendLive(sent)
        XCTAssertEqual(model.pendingBottomScroll, sent.id)
    }

    /// No send in flight and the timeline settled: an incoming message must not
    /// scroll-jack a reader who's browsing history.
    @MainActor
    func testIncomingMessageWithoutSendDoesNotPin() async throws {
        let model = try await loadedModel()
        model.consumeBottomScroll()
        let incoming = trailing("incoming", isOutgoing: false, in: model)
        model.appendLive(incoming)
        XCTAssertNil(model.pendingBottomScroll)
    }

    /// Selecting a fresh thread must not carry a still-armed send-follow across:
    /// the next thread's incoming message shouldn't be treated as a sent row.
    @MainActor
    func testSelectResetsPendingSendFollow() async throws {
        let model = try await loadedModel()
        model.scrollToBottom()           // arm, but the row never lands
        let conversations = try await FixtureProvider()
            .conversations(page: ConversationPageRequest(limit: 100)).conversations
        let other = try XCTUnwrap(conversations.dropFirst().first ?? conversations.first)
        model.select(other)
        for _ in 0..<200 where model.state != .loaded {
            try await Task.sleep(for: .milliseconds(10))
        }
        model.consumeBottomScroll()
        let incoming = trailing("next-thread", isOutgoing: false, in: model)
        model.appendLive(incoming)
        XCTAssertNil(model.pendingBottomScroll)
    }
}
