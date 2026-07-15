import XCTest
@testable import NativeMessages

final class NeedsReplyTests: XCTestCase {
    private func fixtureConversations() async throws -> [Conversation] {
        try await FixtureProvider().conversations(page: ConversationPageRequest(limit: 100)).conversations
    }

    private func conversation(_ name: String, in list: [Conversation]) throws -> Conversation {
        try XCTUnwrap(list.first { $0.displayName == name })
    }

    /// Both inbound threads (last message from them) that have waited past the
    /// threshold surface, most-overdue first; the thread I answered last does not.
    func testInboundThreadsPastThresholdSurface() async throws {
        let conversations = try await fixtureConversations()
        let group = try conversation("Weekend Plans", in: conversations)
        let now = group.lastActivity.addingTimeInterval(4 * 60 * 60)

        let names = NeedsReply.filter(conversations, now: now).map(\.displayName)

        // Avery Chen (older inbound) sorts ahead of Weekend Plans; Riley Park
        // (last message from me) is absent.
        XCTAssertEqual(names, ["Avery Chen", "Weekend Plans"], "unexpected: \(names)")
    }

    /// A thread whose last message is mine never needs a reply, no matter how old.
    func testMyOwnLastMessageNeverNeedsReply() async throws {
        let conversations = try await fixtureConversations()
        let sms = try conversation("Riley Park", in: conversations)
        XCTAssertTrue(sms.lastMessageFromMe)

        let now = sms.lastActivity.addingTimeInterval(365 * 24 * 60 * 60)
        XCTAssertFalse(NeedsReply.needsReply(sms, now: now))
    }

    /// Recent inbound back-and-forth stays out of the triage view until it has
    /// actually gone unanswered for the threshold.
    func testRecentInboundIsBelowThreshold() async throws {
        let conversations = try await fixtureConversations()
        let group = try conversation("Weekend Plans", in: conversations)
        let now = group.lastActivity.addingTimeInterval(60 * 60)

        XCTAssertFalse(NeedsReply.needsReply(group, now: now))
        // The much older Avery Chen thread is still overdue and remains.
        XCTAssertEqual(NeedsReply.filter(conversations, now: now).map(\.displayName), ["Avery Chen"])
    }

    /// The threshold is inclusive: exactly N hours of silence qualifies.
    func testThresholdBoundaryIsInclusive() async throws {
        let conversations = try await fixtureConversations()
        let group = try conversation("Weekend Plans", in: conversations)
        let now = group.lastActivity.addingTimeInterval(NeedsReply.defaultThreshold)

        XCTAssertTrue(NeedsReply.needsReply(group, now: now))
    }
}
