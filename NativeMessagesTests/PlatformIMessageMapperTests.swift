import PlatformSDK
import XCTest
@testable import NativeMessages

final class PlatformIMessageMapperTests: XCTestCase {
    func testThreadMappingQualifiesIdentityAndPreservesParticipants() {
        let user = PlatformSDK.User(
            id: "person-1",
            displayText: "Avery Example",
            email: "avery@example.invalid"
        )
        let participant = PlatformSDK.Participant(user: user)
        let thread = PlatformSDK.Thread(
            id: "iMessage;-;fixture-guid",
            title: "Mapped Fixture",
            isUnread: true,
            isReadOnly: false,
            type: .single,
            timestamp: 1_735_689_600_000,
            messages: PlatformSDK.Paginated(items: [], hasMore: false),
            participants: PlatformSDK.Paginated(items: [participant], hasMore: false),
            unreadCount: 3
        )

        let mapped = PlatformIMessageMapper.conversation(thread)

        XCTAssertEqual(mapped.id.provider, PlatformIMessageMapper.providerID)
        XCTAssertEqual(mapped.id.externalGUID, thread.id)
        XCTAssertEqual(mapped.displayName, "Mapped Fixture")
        XCTAssertEqual(mapped.kind, .direct)
        XCTAssertEqual(mapped.participants.first?.handle, "avery@example.invalid")
        XCTAssertEqual(mapped.unreadCount, 3)
    }

    func testMessageMappingPreservesAttachmentReactionAndReplyMetadata() {
        let attachment = PlatformSDK.Attachment(
            id: "attachment-1",
            type: .img,
            mimeType: "image/png",
            fileName: "fixture.png",
            fileSize: 42,
            loading: true,
            srcURL: "asset://attachment-1"
        )
        let reaction = PlatformSDK.MessageReaction(
            id: "person-1like",
            reactionKey: "like",
            participantID: "person-1"
        )
        let source = PlatformSDK.Message(
            id: "message-1",
            timestamp: 1_735_689_600_000,
            senderID: "person-1",
            text: "Mapped body",
            attachments: [attachment],
            reactions: [reaction],
            isDelivered: true,
            isSender: false,
            linkedMessageID: "message-0",
            cursor: "cursor-1"
        )
        let conversationID = ConversationID(
            provider: PlatformIMessageMapper.providerID,
            externalGUID: "iMessage;-;fixture-guid"
        )

        let mapped = PlatformIMessageMapper.message(source, conversationID: conversationID)

        XCTAssertEqual(mapped.id.externalGUID, "message-1")
        XCTAssertEqual(mapped.providerSequence, "cursor-1")
        XCTAssertEqual(mapped.attachments.first?.availability, .downloadRequired)
        XCTAssertEqual(mapped.attachments.first?.isImage, true)
        XCTAssertEqual(mapped.reactions.first?.kind, .like)
        XCTAssertEqual(mapped.replyTo?.externalGUID, "message-0")
        XCTAssertEqual(mapped.deliveryState, .delivered)
    }
}
