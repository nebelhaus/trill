import Foundation

enum MessageServiceKind: String, Codable, Sendable {
    case iMessage
    case sms
    case rcs
    case unknown
}

enum ConversationKind: String, Codable, Sendable {
    case direct
    case group
}

struct Participant: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let displayName: String?
    let handle: String
    let avatarData: Data?

    init(id: String, displayName: String?, handle: String, avatarData: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.handle = handle
        self.avatarData = avatarData
    }
}

struct Conversation: Hashable, Codable, Sendable, Identifiable {
    let id: ConversationID
    let displayName: String
    let systemName: String?
    let participants: [Participant]
    let kind: ConversationKind
    let service: MessageServiceKind
    let lastActivity: Date
    let lastMessagePreview: String
    let unreadCount: Int?
}

enum AttachmentAvailability: String, Codable, Sendable {
    case available
    case missing
    case downloadRequired
}

struct MessageAttachment: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let displayName: String
    let mimeType: String?
    let uniformTypeIdentifier: String?
    let byteCount: Int64?
    let localURL: URL?
    let availability: AttachmentAvailability
    let isImage: Bool
}

enum ReactionKind: String, Codable, Sendable {
    case love
    case like
    case dislike
    case laugh
    case emphasis
    case question
    case custom
}

struct MessageReaction: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let kind: ReactionKind
    let senderDisplayName: String
    let glyph: String
}

enum MessageDeliveryState: String, Codable, Sendable {
    case unknown
    case pending
    case sent
    case delivered
    case failed
}

struct Message: Hashable, Codable, Sendable, Identifiable {
    let id: MessageID
    let conversationID: ConversationID
    let providerSequence: String?
    let sender: Participant?
    let isOutgoing: Bool
    let text: String
    let createdAt: Date
    let sentAt: Date?
    let deliveredAt: Date?
    let attachments: [MessageAttachment]
    let reactions: [MessageReaction]
    let replyTo: MessageID?
    let threadOrigin: MessageID?
    let service: MessageServiceKind
    let deliveryState: MessageDeliveryState
    let readAt: Date?
    let isEdited: Bool

    init(
        id: MessageID,
        conversationID: ConversationID,
        providerSequence: String?,
        sender: Participant?,
        isOutgoing: Bool,
        text: String,
        createdAt: Date,
        sentAt: Date?,
        deliveredAt: Date?,
        attachments: [MessageAttachment],
        reactions: [MessageReaction],
        replyTo: MessageID?,
        threadOrigin: MessageID?,
        service: MessageServiceKind,
        deliveryState: MessageDeliveryState,
        readAt: Date? = nil,
        isEdited: Bool = false
    ) {
        self.id = id
        self.conversationID = conversationID
        self.providerSequence = providerSequence
        self.sender = sender
        self.isOutgoing = isOutgoing
        self.text = text
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.attachments = attachments
        self.reactions = reactions
        self.replyTo = replyTo
        self.threadOrigin = threadOrigin
        self.service = service
        self.deliveryState = deliveryState
        self.readAt = readAt
        self.isEdited = isEdited
    }
}

struct EventCursor: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

enum ProviderEvent: Sendable {
    case messageAdded(Message, cursor: EventCursor)
    case conversationUpdated(Conversation, cursor: EventCursor)
    case healthChanged(ProviderHealth)
}

struct ConversationPageRequest: Hashable, Sendable {
    let limit: Int
    let cursor: String?

    init(limit: Int = 40, cursor: String? = nil) {
        self.limit = max(1, min(limit, 200))
        self.cursor = cursor
    }
}

struct ConversationPage: Sendable {
    let conversations: [Conversation]
    let nextCursor: String?
}

struct MessagePageRequest: Hashable, Sendable {
    let limit: Int
    let before: String?

    init(limit: Int = 40, before: String? = nil) {
        self.limit = max(1, min(limit, 200))
        self.before = before
    }
}

struct MessagePage: Sendable {
    let messages: [Message]
    let nextBefore: String?
}

struct MessageSearchQuery: Hashable, Sendable {
    let text: String
    let conversationID: ConversationID?
    let limit: Int
    let cursor: String?

    init(text: String, conversationID: ConversationID? = nil, limit: Int = 50, cursor: String? = nil) {
        self.text = text
        self.conversationID = conversationID
        self.limit = max(1, min(limit, 200))
        self.cursor = cursor
    }
}

struct MessageSearchPage: Sendable {
    let messages: [Message]
    let nextCursor: String?
}

struct SendRequest: Sendable {
    let operationID: UUID
    let conversationID: ConversationID
    let text: String
    let attachments: [URL]
}

enum UserFacingSendError: String, Error, Codable, Sendable {
    case unsupported
    case permissionDenied
    case invalidRequest
    case providerUnavailable
    case manualVerificationRequired
}

enum SendOutcome: Sendable {
    case accepted(operationID: UUID)
    case confirmed(operationID: UUID, messageID: MessageID)
    case rejected(operationID: UUID, reason: UserFacingSendError)
    case unknown(operationID: UUID, diagnosticCode: String)
}

struct ReactionRequest: Sendable {
    let operationID: UUID
    let messageID: MessageID
    let kind: ReactionKind
}

enum ReactionOutcome: Sendable {
    case confirmed(operationID: UUID)
    case rejected(operationID: UUID, reason: UserFacingSendError)
    case unknown(operationID: UUID, diagnosticCode: String)
}

enum SendRetryPolicy {
    static func shouldAutomaticallyRetry(_ outcome: SendOutcome) -> Bool {
        // Sending is intentionally send-once. In particular, an unknown result may
        // already have reached Messages.app and must be reconciled before user retry.
        false
    }
}

