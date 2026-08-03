import Foundation
import XCTest
@testable import Trill

/// End-to-end reads through `BeeperProvider`, against the stubbed transport.
/// No network, no Keychain: the configuration source is constructed over a
/// private `UserDefaults` suite and a private Keychain service that is never
/// written to — the provider is handed its session directly.
final class BeeperProviderTests: XCTestCase {
    private let beeper = ProviderID(rawValue: "beeper")

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stub(path: "/v1/accounts", json: BeeperFixtures.accountsJSON)
        StubURLProtocol.stub(path: "/v1/chats", json: BeeperFixtures.chatsPageJSON)
        StubURLProtocol.stub(
            path: "/v1/chats/!fixtureDirect:example.invalid/messages",
            json: BeeperFixtures.messagesPageJSON
        )
        StubURLProtocol.stub(path: "/v1/messages/search", json: BeeperFixtures.messagesPageJSON)
        StubURLProtocol.stub(path: "/v1/info", json: BeeperFixtures.infoJSON)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeProvider() -> BeeperProvider {
        BeeperProvider(
            source: StubConfigurationSource(),
            session: StubURLProtocol.session()
        )
    }

    /// The whole point of the exclusion: Trill already has native iMessage, so
    /// Beeper's copy must never reach the inbox — once via the request-time
    /// allowlist, and again at mapping time.
    func testBeepersIMessageChatNeverReachesTheInbox() async throws {
        let provider = makeProvider()

        let page = try await provider.conversations(page: ConversationPageRequest(limit: 50))

        XCTAssertEqual(
            page.conversations.map(\.id.externalGUID),
            ["!fixtureDirect:example.invalid", "!fixtureGroup:example.invalid"]
        )
        XCTAssertFalse(page.conversations.contains { $0.displayName == "Should Never Appear" })

        // And the allowlist rode on the request, not on a post-filter.
        let chatRequest = try XCTUnwrap(
            StubURLProtocol.requests().first { $0.url?.path == "/v1/chats" }?.url
        )
        let accountIDs = (URLComponents(url: chatRequest, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "accountIDs" }
            .compactMap(\.value)
        XCTAssertFalse(accountIDs.contains("local-imessage"))
        XCTAssertTrue(accountIDs.contains("local-whatsappaaa"))
    }

    func testConversationsCarryTheBeeperProviderAndAServiceIdentity() async throws {
        let page = try await makeProvider().conversations(page: ConversationPageRequest(limit: 50))

        XCTAssertTrue(page.conversations.allSatisfy { $0.id.provider == beeper })
        XCTAssertEqual(
            page.conversations.map(\.service.networkKey).sorted(),
            ["slackgo", "whatsapp"]
        )
    }

    func testNextCursorComesFromOldestCursorOnlyWhenThereIsMore() async throws {
        let page = try await makeProvider().conversations(page: ConversationPageRequest(limit: 50))

        XCTAssertEqual(page.nextCursor, "cursor-older")
    }

    /// The API returns newest-first; the timeline wants oldest-first, matching
    /// every other provider.
    func testMessagesArriveOldestFirstAndFiltered() async throws {
        let conversation = ConversationID(provider: beeper, externalGUID: "!fixtureDirect:example.invalid")

        let page = try await makeProvider().messages(
            in: conversation,
            page: MessagePageRequest(limit: 50)
        )

        XCTAssertEqual(
            page.messages.map(\.id.externalGUID),
            ["msg-1", "msg-2", "msg-3", "msg-failed"]
        )
        XCTAssertNil(page.nextBefore, "hasMore is false in the fixture")
        XCTAssertTrue(page.messages.allSatisfy { $0.conversationID == conversation })
    }

    func testMessagesForAnotherProviderAreRejected() async {
        let foreign = ConversationID(provider: ProviderID(rawValue: "imessage"), externalGUID: "x")

        do {
            _ = try await makeProvider().messages(in: foreign, page: MessagePageRequest(limit: 10))
            XCTFail("expected a routing failure")
        } catch let error as MessagesProviderError {
            guard case .wrongProvider = error else { return XCTFail("expected .wrongProvider") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testReplyQuoteIsHydratedFromTheSamePage() async throws {
        let conversation = ConversationID(provider: beeper, externalGUID: "!fixtureDirect:example.invalid")

        let page = try await makeProvider().messages(
            in: conversation,
            page: MessagePageRequest(limit: 50)
        )
        let reply = try XCTUnwrap(page.messages.first { $0.id.externalGUID == "msg-2" })

        XCTAssertEqual(reply.quoted?.id.externalGUID, "msg-1")
    }

    func testSearchPushesFiltersDownAndStillAppliesTheLocalPredicate() async throws {
        let page = try await makeProvider().search(MessageSearchQuery(text: "welcome", limit: 20))

        // Server-side narrowing happened…
        let request = try XCTUnwrap(
            StubURLProtocol.requests().first { $0.url?.path == "/v1/messages/search" }?.url
        )
        let items = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "query" }?.value, "welcome")

        // …and the local predicate still ran over what came back, so the fixture
        // page (which the stub returns wholesale) narrows to the real match.
        XCTAssertEqual(page.messages.map(\.id.externalGUID), ["msg-1"])
    }

    // MARK: - Health

    /// A REST provider has no messages database, and `ProviderHealth`'s first
    /// field is named after one. The real state belongs in `remoteRelay`, which
    /// is also what the composite's `headline` prefers.
    func testHealthReportsTheRelayDimensionNotTheDatabaseOne() async {
        let health = await makeProvider().health()

        XCTAssertEqual(health.messagesDatabase.reason, .notRequested)
        XCTAssertEqual(health.remoteRelay?.availability, .available)
        XCTAssertEqual(health.sending.reason, .disabled, "no send path exists in this phase")
    }

    func testUnreachableServerIsAProviderFailureOnTheRelayDimension() async {
        StubURLProtocol.reset()
        let health = await makeProvider().health()

        XCTAssertEqual(health.remoteRelay?.availability, .unavailable)
        XCTAssertEqual(health.remoteRelay?.reason, .providerFailure)
        XCTAssertEqual(
            health.messagesDatabase.reason,
            .notRequested,
            "a Beeper outage must never look like a chat.db permission failure"
        )
    }

    func testRejectedTokenReadsAsPermissionMissing() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub(path: "/v1/info", status: 401, json: "{}")

        let health = await makeProvider().health()

        XCTAssertEqual(health.remoteRelay?.reason, .permissionMissing)
    }

    // MARK: - Writes stay refused

    func testSendAndReactAreRefusedRatherThanSilentlyIgnored() async throws {
        let provider = makeProvider()
        let conversation = ConversationID(provider: beeper, externalGUID: "!fixtureDirect:example.invalid")
        let operation = UUID()

        let send = try await provider.send(SendRequest(
            operationID: operation,
            conversationID: conversation,
            text: "nope",
            attachments: []
        ))
        let react = try await provider.react(ReactionRequest(
            operationID: operation,
            messageID: MessageID(provider: beeper, externalGUID: "msg-1"),
            kind: .like
        ))

        guard case let .rejected(_, reason) = send, reason == .unsupported else {
            return XCTFail("send must be rejected, not accepted")
        }
        guard case let .rejected(_, reactReason) = react, reactReason == .unsupported else {
            return XCTFail("react must be rejected, not accepted")
        }
        let capabilities = await provider.capabilities()
        XCTAssertFalse(
            capabilities.supports(.sendText),
            "and the capability must not be advertised either"
        )
    }
}

/// Supplies a fixed loopback configuration without touching `UserDefaults` or
/// the real Keychain.
private struct StubConfigurationSource: BeeperConfigurationProviding {
    func current() throws -> BeeperConfiguration? {
        try BeeperConfiguration(
            endpoint: BeeperConfiguration.defaultEndpoint,
            accessToken: "fixture-token"
        )
    }
}
