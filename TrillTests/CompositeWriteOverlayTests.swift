import XCTest
@testable import Trill

/// Vetting-vehicle tests for the platform-imessage write overlay (tapbacks).
/// The unit-testable subset of ADR 0001's safe-enablement criteria; the
/// signed-host criteria (2/3/5) live in the manual handoff checklist.
///
/// These run without a signed host, without Accessibility, and without ever
/// constructing `PlatformAPI`: in a plain test process `AXIsProcessTrusted()` is
/// false, so the write backend fails closed with `.permissionDenied` before it
/// would ever touch Messages.app or `chat.db`.
final class CompositeWriteOverlayTests: XCTestCase {

    // MARK: - ReactionKind ⇄ reactionKey mapping

    func testReactionKeyMappingCoversTheSixStandardTapbacks() {
        XCTAssertEqual(PlatformWriteBackend.reactionKey(for: .love), "heart")
        XCTAssertEqual(PlatformWriteBackend.reactionKey(for: .like), "like")
        XCTAssertEqual(PlatformWriteBackend.reactionKey(for: .dislike), "dislike")
        XCTAssertEqual(PlatformWriteBackend.reactionKey(for: .laugh), "laugh")
        XCTAssertEqual(PlatformWriteBackend.reactionKey(for: .emphasis), "emphasize")
        XCTAssertEqual(PlatformWriteBackend.reactionKey(for: .question), "question")
    }

    func testCustomReactionIsNotYetSendable() {
        // Custom emoji reactions need the macOS 15 picker automation path we don't
        // wire yet; they must reject as unsupported rather than silently no-op.
        XCTAssertNil(PlatformWriteBackend.reactionKey(for: .custom))
    }

    func testSendableTapbackMenuMatchesTheSendableKinds() {
        // The context-menu list and the backend's sendable keys must not drift:
        // every menu entry must map to a real reactionKey.
        for tapback in Tapback.sendable {
            XCTAssertNotNil(
                PlatformWriteBackend.reactionKey(for: tapback.kind),
                "Tapback menu offers \(tapback.kind) but the backend can't send it"
            )
        }
        XCTAssertEqual(Tapback.sendable.count, 6)
    }

    // MARK: - canReact gate (capability AND advanced-actions health)

    func testCanReactRequiresBothCapabilityAndLiveHealth() {
        let capable = ProviderCapabilities([.sendStandardReactions])
        let live = healthWithAdvanced(.available)
        XCTAssertTrue(CapabilityGate.canReact(capabilities: capable, health: live))
    }

    func testCanReactFailsClosedWithoutCapability() {
        let health = healthWithAdvanced(.available)
        XCTAssertFalse(CapabilityGate.canReact(capabilities: ProviderCapabilities(), health: health))
    }

    func testCanReactFailsClosedWhenAdvancedHealthNotAvailable() {
        let capable = ProviderCapabilities([.sendStandardReactions])
        XCTAssertFalse(CapabilityGate.canReact(capabilities: capable, health: healthWithAdvanced(.limited)))
        // The baseline read-only provider leaves advancedActions nil entirely.
        XCTAssertFalse(CapabilityGate.canReact(capabilities: capable, health: .fixture))
    }

    // MARK: - Composite provider

    func testCompositeAddsReactionCapabilityOnTopOfBase() async {
        let composite = CompositeMessagesProvider(base: StubBaseProvider())
        let caps = await composite.capabilities()
        XCTAssertTrue(caps.supports(.sendStandardReactions))
        // Base capabilities are preserved, not replaced.
        XCTAssertTrue(caps.supports(.readMessages))
        XCTAssertTrue(caps.supports(.sendText))
    }

    func testCompositePopulatesAdvancedActionsHealthFromBackend() async {
        let composite = CompositeMessagesProvider(base: StubBaseProvider())
        let health = await composite.health()
        // Base dimensions pass through unchanged...
        XCTAssertEqual(health.messagesDatabase.availability, .available)
        // ...and the advanced-actions dimension is now populated (not nil). In a
        // non-Accessibility test host it resolves to a non-available state.
        XCTAssertNotNil(health.advancedActions)
        XCTAssertNotEqual(health.advancedActions?.availability, .available)
    }

    func testCompositeRoutesReactToBackendNotBase() async throws {
        let composite = CompositeMessagesProvider(base: StubBaseProvider())
        let outcome = try await composite.react(ReactionRequest(
            operationID: UUID(),
            conversationID: ConversationID(provider: composite.id, externalGUID: "iMessage;-;+15550001111"),
            messageID: MessageID(provider: composite.id, externalGUID: "GUID-1"),
            kind: .love
        ))
        // The stub base returns .unsupported for react; the backend (Accessibility
        // not trusted in tests) returns .rejected(.permissionDenied). Seeing the
        // latter proves the composite routed to the backend, not the base — and
        // that it fails closed without constructing PlatformAPI.
        guard case let .rejected(_, reason) = outcome else {
            return XCTFail("Expected a rejected outcome, got \(outcome)")
        }
        XCTAssertEqual(reason, .permissionDenied)
    }

    func testCompositeForwardsReadsToBase() async throws {
        let composite = CompositeMessagesProvider(base: StubBaseProvider())
        let page = try await composite.conversations(page: ConversationPageRequest(limit: 10))
        // Sentinel proves the read came straight from the base provider.
        XCTAssertEqual(page.conversations.first?.displayName, StubBaseProvider.sentinelName)
    }

    // MARK: - Helpers

    private func healthWithAdvanced(_ availability: HealthAvailability) -> ProviderHealth {
        var health = ProviderHealth.fixture
        health.advancedActions = HealthState(availability: availability, reason: .ready, recoverySuggestion: nil)
        return health
    }
}

/// Minimal read-only baseline stand-in. Advertises the same read + text-send
/// capabilities `LiveIMessageProvider` does, and rejects `react` as `.unsupported`
/// (the native path can't tapback) so routing to the write backend is observable.
private struct StubBaseProvider: MessagesProvider {
    static let sentinelName = "Base Read Sentinel"

    let id = ProviderID(rawValue: "stub-base")

    func health() async -> ProviderHealth { .ready }

    func capabilities() async -> ProviderCapabilities {
        ProviderCapabilities([.readConversations, .readMessages, .search, .watchLiveEvents, .sendText])
    }

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        ConversationPage(
            conversations: [
                Conversation(
                    id: ConversationID(provider: id, externalGUID: "iMessage;-;sentinel"),
                    displayName: Self.sentinelName,
                    systemName: nil,
                    participants: [],
                    kind: .direct,
                    service: .iMessage,
                    lastActivity: Date(timeIntervalSince1970: 0),
                    lastMessagePreview: "",
                    unreadCount: 0,
                    lastMessageFromMe: true,
                    reactedToLatestInbound: false
                )
            ],
            nextCursor: nil
        )
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        MessagePage(messages: [], nextBefore: nil)
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        MessageSearchPage(messages: [], nextCursor: nil)
    }

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        .accepted(operationID: request.operationID)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }
}

extension ProviderHealth {
    fileprivate static let ready = ProviderHealth(
        messagesDatabase: .ready,
        liveEvents: .ready,
        sending: .ready,
        contacts: .notRequested,
        notifications: .notRequested,
        remoteRelay: nil
    )
}
