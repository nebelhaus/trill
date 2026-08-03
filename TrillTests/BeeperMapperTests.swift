import Foundation
import XCTest
@testable import Trill

/// Contract-fixture tests for the Beeper adapter, in the shape of
/// `PlatformIMessageMapperTests`. Fixtures are synthesized (`BeeperFixtures`);
/// nothing here touches the network or the Keychain.
final class BeeperMapperTests: XCTestCase {
    private let beeper = ProviderID(rawValue: "beeper")

    private func accounts() throws -> [BeeperAccount] {
        try BeeperFixtures.decode([BeeperAccount].self, from: BeeperFixtures.accountsJSON)
    }

    private func chats() throws -> BeeperPage<BeeperChat> {
        try BeeperFixtures.decode(BeeperPage<BeeperChat>.self, from: BeeperFixtures.chatsPageJSON)
    }

    private func messages() throws -> BeeperPage<BeeperMessage> {
        try BeeperFixtures.decode(BeeperPage<BeeperMessage>.self, from: BeeperFixtures.messagesPageJSON)
    }

    // MARK: - Wire decoding

    func testPageEnvelopeDecodes() throws {
        let page = try chats()

        XCTAssertEqual(page.items.count, 3)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.oldestCursor, "cursor-older")
        XCTAssertEqual(page.newestCursor, "cursor-newer")
    }

    func testInfoDecodes() throws {
        let info = try BeeperFixtures.decode(BeeperInfo.self, from: BeeperFixtures.infoJSON)

        XCTAssertEqual(info.app?.version, "0.0.0-fixture")
        XCTAssertNotNil(info.endpoints?.spec)
        XCTAssertNotNil(info.endpoints?.ws_events)
    }

    /// `seen` is `bool | string | map` on the wire. All three must decode; only
    /// the timestamp-bearing shapes can produce a `readAt`.
    func testSeenDecodesAllThreeShapes() throws {
        func seen(_ json: String) throws -> BeeperSeen? {
            try BeeperFixtures.decode(BeeperMessage.self, from: """
            {"id":"m","sortKey":"1","seen":\(json)}
            """).seen
        }

        guard case .flag(true)? = try seen("true") else { return XCTFail("expected a flag") }
        guard case .timestamp? = try seen("\"2026-02-01T10:00:00Z\"") else {
            return XCTFail("expected a timestamp")
        }
        guard case .perUser? = try seen("{\"@a:example.invalid\":\"2026-02-01T10:00:00Z\"}") else {
            return XCTFail("expected a per-user map")
        }
    }

    // MARK: - Service identity

    func testAccountsBecomeServiceIdentities() throws {
        let identities = BeeperMapper.serviceIdentities(for: try accounts())

        // Beeper's own iMessage account never gets an identity, which is what
        // keeps its threads out of an inbox that already has native iMessage.
        XCTAssertNil(identities["local-imessage"])
        XCTAssertEqual(identities["local-whatsappaaa"]?.key, "whatsapp")
        XCTAssertEqual(identities["local-whatsappaaa"]?.displayName, "WhatsApp")
    }

    /// Two Slack accounts on one network are two filter entries sharing one
    /// color; a single-account network keeps the bare network key so adding a
    /// second account later doesn't re-key the first one's saved filter.
    func testTwoAccountsOnOneNetworkGetDistinctKeysAndOneNetwork() throws {
        let identities = BeeperMapper.serviceIdentities(for: try accounts())
        let first = try XCTUnwrap(identities["slackgo.T000-U111"])
        let second = try XCTUnwrap(identities["slackgo.T000-U222"])

        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(first.networkKey, second.networkKey)
        XCTAssertEqual(first.networkKey, "slackgo")
        XCTAssertNotEqual(first.displayName, second.displayName)
        XCTAssertEqual(identities["local-whatsappaaa"]?.accountID, nil)
    }

    func testIMessageAccountsAreRecognizedByBridgeTypeAndID() {
        XCTAssertTrue(BeeperMapper.isIMessage(accountID: "local-imessage", bridgeType: "imessage"))
        XCTAssertTrue(BeeperMapper.isIMessage(accountID: "whatever", bridgeType: "imessage"))
        XCTAssertTrue(BeeperMapper.isIMessage(accountID: "local-imessage", bridgeType: nil))
        XCTAssertFalse(BeeperMapper.isIMessage(accountID: "local-whatsappaaa", bridgeType: "whatsapp"))
    }

    // MARK: - Chats

    func testChatMapsToConversationUsingTheGlobalID() throws {
        let identities = BeeperMapper.serviceIdentities(for: try accounts())
        let chat = try XCTUnwrap(chats().items.first)
        let service = try XCTUnwrap(identities[chat.accountID])
        let conversation = BeeperMapper.conversation(chat, service: service)

        // `Chat.id`, never `localChatID` — the latter is installation-specific,
        // and `persistenceKey` is the primary key of every overlay table.
        XCTAssertEqual(conversation.id.externalGUID, "!fixtureDirect:example.invalid")
        XCTAssertNotEqual(conversation.id.externalGUID, chat.localChatID)
        XCTAssertEqual(conversation.id.provider, beeper)
        XCTAssertEqual(conversation.displayName, "Fixture Contact")
        XCTAssertEqual(conversation.kind, .direct)
        XCTAssertEqual(conversation.unreadCount, 2)
        XCTAssertEqual(conversation.service.key, "whatsapp")
        XCTAssertEqual(conversation.participants.map(\.handle), ["+15550000000"])
        XCTAssertFalse(conversation.lastMessageFromMe)
        XCTAssertEqual(conversation.lastMessagePreview, "Second fixture line")
    }

    func testGroupChatMapsToGroupKind() throws {
        let identities = BeeperMapper.serviceIdentities(for: try accounts())
        let chat = try XCTUnwrap(chats().items.first { $0.type == "group" })
        let conversation = BeeperMapper.conversation(
            chat,
            service: try XCTUnwrap(identities[chat.accountID])
        )

        XCTAssertEqual(conversation.kind, .group)
        XCTAssertEqual(conversation.unreadCount, nil, "zero unread reads as no badge")
    }

    /// A chat with no zero-unread badge and no preview must not land in the
    /// needs-reply triage view on a guess.
    func testChatWithoutPreviewCountsAsAnswered() throws {
        let identities = BeeperMapper.serviceIdentities(for: try accounts())
        let chat = try XCTUnwrap(chats().items.first { $0.type == "group" })
        let conversation = BeeperMapper.conversation(
            chat,
            service: try XCTUnwrap(identities[chat.accountID])
        )

        XCTAssertTrue(conversation.lastMessageFromMe)
        XCTAssertFalse(conversation.reactedToLatestInbound)
    }

    // MARK: - Messages

    private func mapped() throws -> [Message] {
        let conversationID = ConversationID(provider: beeper, externalGUID: "!fixtureDirect:example.invalid")
        return try messages().items
            .filter(BeeperMapper.isRenderable)
            .map { BeeperMapper.message($0, conversationID: conversationID, service: .init(key: "whatsapp", displayName: "WhatsApp", networkKey: "whatsapp")) }
    }

    /// The stream carries non-messages. Letting them through renders blank
    /// bubbles in the timeline.
    func testNonMessagesAreFilteredOut() throws {
        let ids = try mapped().map(\.id.externalGUID)

        XCTAssertFalse(ids.contains("msg-reaction"), "type: REACTION is not a message")
        XCTAssertFalse(ids.contains("msg-notice"), "type: NOTICE is a state event")
        XCTAssertFalse(ids.contains("msg-deleted"))
        XCTAssertFalse(ids.contains("msg-hidden"))
        XCTAssertEqual(ids, ["msg-1", "msg-2", "msg-3", "msg-failed"])
    }

    /// `text` is Matrix HTML and `Message.text` is a plain `String`. Handing
    /// markup to a `Text` view shows the tags.
    func testMatrixHTMLIsFlattenedToPlainText() throws {
        let first = try XCTUnwrap(mapped().first { $0.id.externalGUID == "msg-1" })

        XCTAssertEqual(first.text, "Hello & welcome\nSecond paragraph")
        XCTAssertFalse(first.text.contains("<"))
        XCTAssertFalse(first.text.contains("&amp;"))
    }

    func testSortKeyBecomesTheProviderSequence() throws {
        let messages = try mapped()

        XCTAssertEqual(messages.map(\.providerSequence), ["0000000100", "0000000200", "0000000300", "0000000800"])
    }

    func testDeliveryStateAndEditAndReadMapping() throws {
        let reply = try XCTUnwrap(mapped().first { $0.id.externalGUID == "msg-2" })
        let failed = try XCTUnwrap(mapped().first { $0.id.externalGUID == "msg-failed" })

        XCTAssertTrue(reply.isOutgoing)
        XCTAssertEqual(reply.deliveryState, .delivered, "SUCCESS with recipients is delivered")
        XCTAssertTrue(reply.isEdited)
        XCTAssertNotNil(reply.readAt)
        XCTAssertEqual(reply.replyTo?.externalGUID, "msg-1")
        XCTAssertEqual(failed.deliveryState, .failed)
    }

    /// `ReactionKind` is an iMessage-shaped closed enum; an arbitrary emoji or a
    /// network shortcode is `.custom` carrying the key verbatim, not a new case.
    func testReactionsMapToCustomWithTheKeyAsGlyph() throws {
        let reply = try XCTUnwrap(mapped().first { $0.id.externalGUID == "msg-2" })

        XCTAssertEqual(reply.reactions.map(\.kind), [.custom, .custom])
        XCTAssertEqual(reply.reactions.map(\.glyph), ["🎉", "smiling-face"])
    }

    /// Beeper's `srcURL` "may be temporary or local-only", and any local path it
    /// reports lives inside *Beeper's* storage. Neither may become `localURL`.
    func testAttachmentsAreDownloadRequiredAndNeverPointIntoBeeperStorage() throws {
        let media = try XCTUnwrap(mapped().first { $0.id.externalGUID == "msg-3" })
        let attachment = try XCTUnwrap(media.attachments.first)

        XCTAssertEqual(attachment.availability, .downloadRequired)
        XCTAssertNil(attachment.localURL)
        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.byteCount, 2048)
        XCTAssertEqual(attachment.id, "mxc://example.invalid/fixtureAsset")
    }

    func testReplyQuoteHydratesFromTheSamePage() throws {
        let conversationID = ConversationID(provider: beeper, externalGUID: "!fixtureDirect:example.invalid")
        let items = try messages().items
        let parent = try XCTUnwrap(items.first { $0.id == "msg-1" })
        let reply = try XCTUnwrap(items.first { $0.id == "msg-2" })
        let mapped = BeeperMapper.message(
            reply,
            conversationID: conversationID,
            service: .iMessage,
            quoted: BeeperMapper.quotedMessage(parent)
        )

        XCTAssertEqual(mapped.quoted?.id.externalGUID, "msg-1")
        XCTAssertEqual(mapped.quoted?.senderName, "Fixture Contact")
        XCTAssertEqual(mapped.quoted?.text, "Hello & welcome\nSecond paragraph")
    }

    // MARK: - Search push-down

    func testSearchFiltersArePushedDownToTheServer() {
        var filters = SearchFilters()
        filters.sender = "me"
        filters.conversationKind = .group
        filters.requiresImage = true
        filters.after = Date(timeIntervalSince1970: 1_767_225_600)
        filters.unreadOnly = true
        let query = MessageSearchQuery(text: "dinner", limit: 25, filters: filters)

        let parameters = BeeperMapper.searchParameters(
            for: query,
            cursor: "c",
            accountIDs: ["local-whatsappaaa"]
        )

        XCTAssertEqual(parameters.query, "dinner")
        XCTAssertEqual(parameters.sender, "me")
        XCTAssertEqual(parameters.chatType, "group")
        XCTAssertEqual(parameters.mediaTypes, ["image"])
        XCTAssertNotNil(parameters.dateAfter)
        XCTAssertEqual(parameters.accountIDs, ["local-whatsappaaa"])
        XCTAssertEqual(parameters.limit, 25)

        // `is:unread` has no server equivalent and stays a local filter.
        let names = parameters.queryItems.map(\.name)
        XCTAssertFalse(names.contains("unreadOnly"))
    }

    func testSearchScopedToAConversationSendsTheChatID() {
        let scope = ConversationID(provider: beeper, externalGUID: "!fixtureDirect:example.invalid")
        let parameters = BeeperMapper.searchParameters(
            for: MessageSearchQuery(text: "x", conversationID: scope, limit: 10),
            cursor: nil,
            accountIDs: []
        )

        XCTAssertEqual(parameters.chatIDs, ["!fixtureDirect:example.invalid"])
    }

    func testQueryItemsOmitNothingUnset() {
        let parameters = BeeperMapper.searchParameters(
            for: MessageSearchQuery(text: "", limit: 10),
            cursor: nil,
            accountIDs: []
        )
        // `queryItems` keeps nils; the client drops them before building the URL,
        // so an unset filter never becomes `?sender=`.
        let live = parameters.queryItems.filter { $0.value != nil }.map(\.name)
        XCTAssertEqual(live, ["limit"])
    }
}
