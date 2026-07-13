import Foundation
import IMessage
import PlatformSDK

/// Safety-gated adapter for platform-imessage v0.24.4.
///
/// The package is integrated and its public DTOs are mapped below. Live calls
/// are intentionally blocked because the current public `PlatformAPI` creates
/// indexes through a read-write connection to Apple's chat.db. Enabling this
/// adapter requires an upstream/forked public initializer that preserves
/// `IMDatabase(createIndexes: false)` end-to-end.
actor PlatformIMessageProvider: MessagesProvider {
    nonisolated let id = ProviderID(rawValue: "platform-imessage")
    nonisolated static let pinnedVersion = "0.24.4"

    private let accessChecker: MessagesDatabaseAccessChecker

    init(accessChecker: MessagesDatabaseAccessChecker = MessagesDatabaseAccessChecker()) {
        self.accessChecker = accessChecker
    }

    func health() async -> ProviderHealth {
        let databaseProbe = MessagesDatabaseAccessChecker.health(for: accessChecker.probe())
        let databaseState: HealthState
        if databaseProbe.availability == .available {
            databaseState = HealthState(
                availability: .limited,
                reason: .manualVerificationRequired,
                recoverySuggestion: "Live reads remain safety-gated until platform-imessage exposes a no-index public API."
            )
        } else {
            databaseState = databaseProbe
        }
        return ProviderHealth(
            messagesDatabase: databaseState,
            liveEvents: .disabled,
            sending: HealthState(
                availability: .limited,
                reason: .manualVerificationRequired,
                recoverySuggestion: "Sending requires a signed-app Accessibility and Automation validation pass."
            ),
            contacts: .notRequested,
            notifications: .notRequested,
            remoteRelay: nil
        )
    }

    func capabilities() async -> ProviderCapabilities {
        // Capabilities describe what this adapter enables now, not the broader
        // feature set claimed by the underlying package.
        ProviderCapabilities()
    }

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        throw blockedError
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        throw blockedError
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        throw blockedError
    }

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: blockedError)
        }
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        .rejected(operationID: request.operationID, reason: .manualVerificationRequired)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        .rejected(operationID: request.operationID, reason: .manualVerificationRequired)
    }

    private var blockedError: MessagesProviderError {
        .unavailable("platform-imessage's public API may create indexes in chat.db")
    }
}

enum PlatformIMessageMapper {
    static let providerID = ProviderID(rawValue: "platform-imessage")

    static func conversation(_ source: PlatformSDK.Thread) -> Conversation {
        let participants = source.participants.items.map(participant)
        let service = isSMS(extra: source.extra) ? MessageServiceKind.sms : .iMessage
        return Conversation(
            id: ConversationID(provider: providerID, externalGUID: source.id),
            displayName: source.title?.nonEmpty ?? participants.first?.displayName ?? participants.first?.handle ?? "Conversation",
            systemName: source.title,
            participants: participants,
            kind: source.type == .single ? .direct : .group,
            service: service,
            lastActivity: date(milliseconds: source.timestamp ?? source.createdAt ?? 0),
            lastMessagePreview: source.partialLastMessage?.text ?? "",
            unreadCount: source.unreadCount ?? (source.isUnread ? 1 : 0)
        )
    }

    static func message(_ source: PlatformSDK.Message, conversationID: ConversationID) -> Message {
        let service: MessageServiceKind = conversationID.externalGUID.hasPrefix("SMS;") ? .sms : .iMessage
        let sender = source.isSender == true ? nil : Participant(
            id: source.senderID,
            displayName: nil,
            handle: source.senderID
        )
        return Message(
            id: MessageID(provider: providerID, externalGUID: source.id),
            conversationID: conversationID,
            providerSequence: source.cursor,
            sender: sender,
            isOutgoing: source.isSender == true,
            text: source.text ?? "",
            createdAt: date(milliseconds: source.timestamp),
            sentAt: nil,
            deliveredAt: source.isDelivered == true ? date(milliseconds: source.timestamp) : nil,
            attachments: (source.attachments ?? []).map(attachment),
            reactions: (source.reactions ?? []).map(reaction),
            replyTo: source.linkedMessageID.map { MessageID(provider: providerID, externalGUID: $0) },
            threadOrigin: source.linkedMessageID.map { MessageID(provider: providerID, externalGUID: $0) },
            service: service,
            deliveryState: deliveryState(source),
        )
    }

    private static func participant(_ source: PlatformSDK.Participant) -> Participant {
        let user = source.user
        return Participant(
            id: user.id,
            displayName: user.fullName?.nonEmpty ?? user.nickname?.nonEmpty,
            handle: user.phoneNumber?.nonEmpty ?? user.email?.nonEmpty ?? user.username?.nonEmpty ?? user.id
        )
    }

    private static func attachment(_ source: PlatformSDK.Attachment) -> MessageAttachment {
        let fileURL = source.srcURL.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0 : nil }
        let availability: AttachmentAvailability
        if fileURL != nil {
            availability = .available
        } else if source.loading == true || source.srcURL?.hasPrefix("asset://") == true {
            availability = .downloadRequired
        } else {
            availability = .missing
        }
        return MessageAttachment(
            id: source.id,
            displayName: source.fileName?.nonEmpty ?? "Attachment",
            mimeType: source.mimeType,
            uniformTypeIdentifier: nil,
            byteCount: source.fileSize,
            localURL: fileURL,
            availability: availability,
            isImage: source.type == .img
        )
    }

    private static func reaction(_ source: PlatformSDK.MessageReaction) -> MessageReaction {
        let normalized = source.reactionKey.lowercased()
        let mapping: (ReactionKind, String)
        switch normalized {
        case "heart", "love": mapping = (.love, "❤️")
        case "like", "thumbsup": mapping = (.like, "👍")
        case "dislike", "thumbsdown": mapping = (.dislike, "👎")
        case "laugh", "haha": mapping = (.laugh, "😂")
        case "emphasis", "emphasize": mapping = (.emphasis, "‼️")
        case "question": mapping = (.question, "❓")
        default: mapping = (.custom, source.reactionKey)
        }
        return MessageReaction(
            id: source.id,
            kind: mapping.0,
            senderDisplayName: source.participantID,
            glyph: mapping.1
        )
    }

    private static func deliveryState(_ source: PlatformSDK.Message) -> MessageDeliveryState {
        if source.isErrored == true { return .failed }
        if source.isDelivered == true { return .delivered }
        return source.isSender == true ? .sent : .unknown
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func isSMS(extra: Any?) -> Bool {
        (extra as? [String: Any])?["isSMS"] as? Bool == true
    }
}

