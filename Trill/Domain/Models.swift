import Foundation

enum MessageServiceKind: String, Codable, Sendable {
    case iMessage
    case sms
    case rcs
    case unknown

    /// Services the user can show/hide via the sidebar's service filter, in menu
    /// order. `.unknown` is intentionally excluded — it's a catch-all we never
    /// hide, so a stray thread can't vanish behind a filter the user can't see.
    static let togglable: [MessageServiceKind] = [.iMessage, .sms, .rcs]
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
    /// Whether the most recent message in the thread was sent by me. Drives the
    /// needs-reply triage filter: a thread whose last message is *from them*
    /// (this is `false`) and has sat unanswered is what surfaces there.
    let lastMessageFromMe: Bool
    /// Whether I've tapped back on the trailing run of received messages. A
    /// reaction is a lightweight reply, so it also clears a thread out of the
    /// needs-reply triage view even though no message of mine followed.
    let reactedToLatestInbound: Bool
}

/// A user-defined, local-only label a conversation can belong to — the overlay
/// analogue of a mail folder / tag. Membership is many-to-many (a conversation can
/// live in several folders), so folders double as tags. All folder state is owned
/// by `AppDatabase`; chat.db is never touched.
struct Folder: Hashable, Codable, Sendable, Identifiable {
    /// Stable UUID string — survives renames so membership rows never re-key.
    let id: String
    var name: String
    /// One of `Rice.accentNames`; drives the folder's color dot.
    var colorName: String
    /// Ascending sidebar order; new folders append after the current max.
    var sortOrder: Double
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
    let isFromMe: Bool

    init(id: String, kind: ReactionKind, senderDisplayName: String, glyph: String, isFromMe: Bool = false) {
        self.id = id
        self.kind = kind
        self.senderDisplayName = senderDisplayName
        self.glyph = glyph
        self.isFromMe = isFromMe
    }
}

/// Snapshot of the message a reply targets, resolved at mapping time so the
/// quote renders even when the original falls outside the loaded page.
struct QuotedMessage: Hashable, Codable, Sendable {
    let id: MessageID
    let senderName: String
    let text: String
    let hasAttachments: Bool
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
    let quoted: QuotedMessage?

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
        isEdited: Bool = false,
        quoted: QuotedMessage? = nil
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
        self.quoted = quoted
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
    /// The backing store was written but produced no new rows — an edit,
    /// tapback, or delivery/read change to an existing message. Consumers
    /// refresh the open thread in place; carries no payload or cursor.
    case databaseChanged
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

/// A page loaded by the "jump to date" scrubber: a window of messages around a
/// chosen wall-clock date, plus the `anchor` — the first message on or after that
/// date — for the view to scroll to and flash. `page.nextBefore` continues the
/// usual older-message paging from the top of the window. `anchor` is nil when the
/// date falls past the newest message (the window is then just the newest page).
struct DatedMessagePage: Sendable {
    let page: MessagePage
    let anchor: MessageID?
}

/// Structured filters parsed out of a raw search string by `SearchQueryParser`
/// — the `from:`, `in:`, `has:`, `is:`, `before:` and `after:` operators. Each
/// field is one operator; a nil/false/empty field means that operator wasn't
/// used. The residual free text lives on `MessageSearchQuery.text`; these narrow
/// it further. `SearchQueryParser.matches` is the single predicate both the
/// fixture and live providers apply, so the two search paths stay identical.
struct SearchFilters: Hashable, Sendable {
    /// `from:` — the sender's contact name or handle (case-insensitive
    /// substring), or one of me/you/myself for my own messages.
    var sender: String?
    /// `in:group` / `in:direct` — restrict to group or one-to-one threads.
    var conversationKind: ConversationKind?
    /// `has:link` — the message text contains a detectable URL.
    var requiresLink: Bool = false
    /// `has:image` — the message carries at least one image attachment.
    var requiresImage: Bool = false
    /// `has:attachment` / `has:file` — the message carries any attachment.
    var requiresAttachment: Bool = false
    /// `is:unread` — an incoming message in a thread that currently has unread
    /// messages. Per-message read state isn't in the domain model, so this is a
    /// documented over-approximation at the thread level.
    var unreadOnly: Bool = false
    /// `after:YYYY-MM-DD` — created on or after this UTC day boundary.
    var after: Date?
    /// `before:YYYY-MM-DD` — created strictly before this UTC day boundary.
    var before: Date?

    var isEmpty: Bool {
        sender == nil && conversationKind == nil
            && !requiresLink && !requiresImage && !requiresAttachment
            && !unreadOnly && after == nil && before == nil
    }
}

struct MessageSearchQuery: Hashable, Sendable {
    /// Residual free text after operators are stripped — matched as a
    /// case-insensitive substring of the message body.
    let text: String
    let conversationID: ConversationID?
    let limit: Int
    let cursor: String?
    let filters: SearchFilters

    init(
        text: String,
        conversationID: ConversationID? = nil,
        limit: Int = 50,
        cursor: String? = nil,
        filters: SearchFilters = SearchFilters()
    ) {
        self.text = text
        self.conversationID = conversationID
        self.limit = max(1, min(limit, 200))
        self.cursor = cursor
        self.filters = filters
    }

    /// Whether this query has anything to search for — free text or at least one
    /// operator. An all-blank query returns no results rather than everything.
    var hasCriteria: Bool { !text.isEmpty || !filters.isEmpty }
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

/// Send addressed to a raw handle instead of an existing conversation —
/// Messages.app creates the thread if none exists yet.
struct DirectSendRequest: Sendable {
    let operationID: UUID
    let handle: String
    let text: String
}

struct ContactSuggestion: Hashable, Sendable, Identifiable {
    let name: String
    let handle: String

    var id: String { handle }
}

/// The minimum a message contributes to the conversation stats panel: when it
/// landed and who sent it. Kept tiny so the whole thread can be aggregated
/// without decoding bodies, attachments, or reactions.
struct MessageStatSample: Hashable, Sendable {
    let date: Date
    let isFromMe: Bool
}

/// One entry in a conversation's media gallery: an attachment plus enough
/// context to jump back to the message it arrived with.
struct MediaItem: Hashable, Sendable, Identifiable {
    let attachment: MessageAttachment
    let messageID: MessageID
    let createdAt: Date

    var id: String { attachment.id }
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

