import XCTest
@testable import NativeMessages

final class NeedsReplyTests: XCTestCase {
    private func fixtureConversations() async throws -> [Conversation] {
        try await FixtureProvider().conversations(page: ConversationPageRequest(limit: 100)).conversations
    }

    private func conversation(_ name: String, in list: [Conversation]) throws -> Conversation {
        try XCTUnwrap(list.first { $0.displayName == name })
    }

    /// Only a thread whose last message is from them, that I haven't answered
    /// (by message or tapback), and that has waited past the threshold surfaces.
    func testOnlyUnansweredInboundThreadsSurface() async throws {
        let conversations = try await fixtureConversations()
        let group = try conversation("Weekend Plans", in: conversations)
        // Four hours after the newest thread's last activity, so all are "old".
        let now = group.lastActivity.addingTimeInterval(4 * 60 * 60)

        // Weekend Plans: last message from them, but I tapped back → answered.
        // Riley Park: last message from me → answered.
        // Avery Chen: from them, no reaction → the only thread awaiting a reply.
        XCTAssertEqual(NeedsReply.filter(conversations, now: now).map(\.displayName), ["Avery Chen"])
    }

    /// A tapback on the latest received message counts as a reply, so the thread
    /// leaves the triage view even though no message of mine followed.
    func testReactingToLatestInboundCountsAsReply() async throws {
        let conversations = try await fixtureConversations()
        let group = try conversation("Weekend Plans", in: conversations)
        XCTAssertFalse(group.lastMessageFromMe)      // last message is from them
        XCTAssertTrue(group.reactedToLatestInbound)  // …but I tapped back on it

        let now = group.lastActivity.addingTimeInterval(4 * 60 * 60)
        XCTAssertFalse(NeedsReply.needsReply(group, now: now))
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
        let avery = try conversation("Avery Chen", in: conversations)
        XCTAssertFalse(avery.lastMessageFromMe)
        XCTAssertFalse(avery.reactedToLatestInbound)
        let now = avery.lastActivity.addingTimeInterval(60 * 60)

        XCTAssertFalse(NeedsReply.needsReply(avery, now: now))
        XCTAssertTrue(NeedsReply.filter(conversations, now: now).isEmpty)
    }

    /// The threshold is inclusive: exactly N hours of silence qualifies.
    func testThresholdBoundaryIsInclusive() async throws {
        let conversations = try await fixtureConversations()
        let avery = try conversation("Avery Chen", in: conversations)
        let now = avery.lastActivity.addingTimeInterval(NeedsReply.defaultThreshold)

        XCTAssertTrue(NeedsReply.needsReply(avery, now: now))
    }
}
