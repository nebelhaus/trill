import Foundation

/// Beeper wire types → Trill domain models. The only place the two vocabularies
/// meet; nothing above `Providers/Beeper/` sees a DTO (`ARCHITECTURE.md §20`).
enum BeeperMapper {
    static let providerID = ProviderID(rawValue: "beeper")

    // MARK: - Accounts and service identity

    /// Whether an account is Beeper's own iMessage bridge.
    ///
    /// Trill already has native iMessage, so surfacing Beeper's too would show
    /// every thread twice. This is checked at *request* time via the `accountIDs`
    /// allowlist — fetching and discarding would also corrupt page sizes — **and**
    /// again here, because the event stream hands us whatever it likes.
    static func isIMessage(_ account: BeeperAccount) -> Bool {
        isIMessage(accountID: account.accountID, bridgeType: account.bridge.type)
    }

    static func isIMessage(accountID: String, bridgeType: String?) -> Bool {
        let haystack = [accountID, bridgeType ?? ""].map { $0.lowercased() }
        return haystack.contains { $0.contains("imessage") || $0 == "sms" }
    }

    /// Service identities for the accounts we're willing to show, keyed by
    /// `accountID`. The account qualifier is folded into the key **only** when a
    /// network has more than one account, so a single-account network keeps the
    /// bare network key and doesn't re-key the user's filter the day they add a
    /// second one.
    static func serviceIdentities(for accounts: [BeeperAccount]) -> [String: ServiceIdentity] {
        let usable = accounts.filter { !isIMessage($0) }
        var accountsPerNetwork: [String: Int] = [:]
        for account in usable {
            accountsPerNetwork[account.bridge.type, default: 0] += 1
        }
        var result: [String: ServiceIdentity] = [:]
        for account in usable {
            let network = account.bridge.type
            let multiple = (accountsPerNetwork[network] ?? 0) > 1
            let label = account.network?.nonEmpty ?? network.capitalizedNetworkName
            result[account.accountID] = ServiceIdentity(
                network: network,
                displayName: multiple ? "\(label) (\(shortAccount(account.accountID)))" : label,
                accountID: multiple ? account.accountID : nil
            )
        }
        return result
    }

    /// A readable tail of an account id for disambiguating two accounts on one
    /// network — `slackgo.T123-U456` reads as `U456`.
    private static func shortAccount(_ accountID: String) -> String {
        let tail = accountID.split(whereSeparator: { $0 == "." || $0 == "-" }).last.map(String.init)
        return tail ?? accountID
    }

    // MARK: - Chats

    static func conversation(
        _ chat: BeeperChat,
        service: ServiceIdentity
    ) -> Conversation {
        let participants = (chat.participants?.items ?? []).map(participant)
        let preview = chat.preview
        let previewText = preview.map { plainText($0) } ?? ""
        return Conversation(
            // `Chat.id`, never `localChatID`: the latter is documented as specific
            // to one Beeper Desktop installation, so baking it into a
            // `ConversationID` would detach every pin, draft, folder membership
            // and saved message the moment the user reinstalls Beeper or moves
            // the Server to another machine.
            id: ConversationID(provider: providerID, externalGUID: chat.id),
            displayName: chat.title?.nonEmpty
                ?? participants.first.map { $0.displayName ?? $0.handle }
                ?? chat.network?.nonEmpty
                ?? "Conversation",
            systemName: chat.title,
            participants: participants,
            kind: chat.type == "group" ? .group : .direct,
            service: service,
            lastActivity: date(chat.lastActivity) ?? .distantPast,
            lastMessagePreview: previewText.nonEmpty
                ?? ((preview?.attachments?.isEmpty == false) ? "Attachment" : ""),
            unreadCount: (chat.unreadCount ?? 0) > 0 ? chat.unreadCount : nil,
            // No preview (or one we can't attribute) counts as "from me" so an
            // unknown thread never falsely lands in needs-reply triage.
            lastMessageFromMe: preview?.isSender ?? true,
            // A `Reaction` carries `participantID` but nothing that says which
            // participant is *me*, so "did I tap back on the trailing inbound
            // run" isn't answerable from a chat-list preview. False is the
            // conservative answer: a thread I only reacted to stays in
            // needs-reply triage rather than silently dropping out of it.
            reactedToLatestInbound: false
        )
    }

    static func participant(_ item: BeeperParticipants.Item) -> Participant {
        Participant(
            id: item.id,
            displayName: item.fullName?.nonEmpty ?? item.username?.nonEmpty,
            handle: item.username?.nonEmpty
                ?? item.phoneNumber?.nonEmpty
                ?? item.email?.nonEmpty
                ?? item.id
        )
    }

    static func contactSuggestion(_ user: BeeperUser) -> ContactSuggestion? {
        let handle = user.username?.nonEmpty
            ?? user.phoneNumber?.nonEmpty
            ?? user.email?.nonEmpty
        guard let handle else { return nil }
        return ContactSuggestion(name: user.fullName?.nonEmpty ?? handle, handle: handle)
    }

    // MARK: - Messages

    /// Whether a wire message is something the timeline should render at all.
    ///
    /// The message stream carries non-messages: `type: 'REACTION'` arrives as a
    /// `Message`, and so do state events (`NOTICE`), deleted rows and hidden
    /// rows. Letting those through renders empty bubbles.
    static func isRenderable(_ message: BeeperMessage) -> Bool {
        if message.isDeleted == true || message.isHidden == true { return false }
        switch message.type {
        case "REACTION", "NOTICE": return false
        default: break
        }
        let hasText = !plainText(message).isEmpty
        let hasAttachments = !(message.attachments ?? []).isEmpty
        return hasText || hasAttachments
    }

    static func message(
        _ source: BeeperMessage,
        conversationID: ConversationID,
        service: ServiceIdentity,
        quoted: QuotedMessage? = nil
    ) -> Message {
        let created = date(source.timestamp) ?? .distantPast
        let isOutgoing = source.isSender ?? false
        return Message(
            id: MessageID(provider: providerID, externalGUID: source.id),
            conversationID: conversationID,
            // `sortKey` is the sortable key and the paging cursor — not the
            // timestamp, which is neither unique nor monotonic.
            providerSequence: source.sortKey,
            sender: isOutgoing ? nil : sender(source),
            isOutgoing: isOutgoing,
            text: plainText(source),
            createdAt: created,
            sentAt: isOutgoing ? created : nil,
            deliveredAt: deliveredAt(source),
            attachments: (source.attachments ?? []).enumerated().map { attachment($1, index: $0, messageID: source.id) },
            reactions: (source.reactions ?? []).map(reaction),
            replyTo: source.linkedMessageID.map { MessageID(provider: providerID, externalGUID: $0) },
            threadOrigin: source.linkedMessageID.map { MessageID(provider: providerID, externalGUID: $0) },
            service: service,
            deliveryState: deliveryState(source),
            readAt: readAt(source),
            isEdited: source.editedTimestamp?.nonEmpty != nil,
            quoted: quoted
        )
    }

    static func quotedMessage(
        _ source: BeeperMessage
    ) -> QuotedMessage {
        QuotedMessage(
            id: MessageID(provider: providerID, externalGUID: source.id),
            senderName: source.isSender == true ? "You" : (source.senderName?.nonEmpty ?? "Participant"),
            text: plainText(source),
            hasAttachments: !(source.attachments ?? []).isEmpty
        )
    }

    private static func sender(_ source: BeeperMessage) -> Participant? {
        guard let id = source.senderID?.nonEmpty else { return nil }
        return Participant(
            id: id,
            displayName: source.senderName?.nonEmpty,
            handle: source.senderName?.nonEmpty ?? id
        )
    }

    /// `text` is Matrix HTML on the wire and a plain `String` in the domain.
    static func plainText(_ source: BeeperMessage) -> String {
        MatrixHTMLText.plainText(from: source.text ?? "")
    }

    static func deliveryState(_ source: BeeperMessage) -> MessageDeliveryState {
        switch source.sendStatus?.status {
        case "SUCCESS": (source.sendStatus?.deliveredToUsers?.isEmpty == false) ? .delivered : .sent
        case "PENDING": .pending
        case "FAIL_RETRIABLE", "FAIL_PERMANENT": .failed
        default: source.isSender == true ? .sent : .unknown
        }
    }

    private static func deliveredAt(_ source: BeeperMessage) -> Date? {
        guard source.sendStatus?.status == "SUCCESS",
              source.sendStatus?.deliveredToUsers?.isEmpty == false
        else { return nil }
        return date(source.sendStatus?.timestamp)
    }

    /// `seen` is `bool | string | map`. Only the timestamp shapes carry a *when*;
    /// a bare `true` says "read" without saying when, which `readAt` can't express
    /// and which nothing in the UI needs.
    private static func readAt(_ source: BeeperMessage) -> Date? {
        switch source.seen {
        case let .timestamp(value): date(value)
        case let .perUser(map): map.values.compactMap(date).max()
        case .flag, .unknown, .none: nil
        }
    }

    /// `ReactionKind` is an iMessage-shaped closed enum. An arbitrary emoji or a
    /// network shortcode is `.custom` carrying the key verbatim as the glyph —
    /// the enum is deliberately *not* extended per network.
    static func reaction(_ source: BeeperReaction) -> MessageReaction {
        MessageReaction(
            id: source.id,
            kind: .custom,
            senderDisplayName: source.participantID ?? "Participant",
            glyph: source.reactionKey,
            isFromMe: false
        )
    }

    /// Attachments are remote and perishable: `srcURL` "may be temporary or
    /// local-only to this device", and any local path the Server reports is
    /// inside *Beeper's* storage. So everything maps to `.downloadRequired` with
    /// no `localURL`; `BeeperAssetCache` fills that in only after the bytes are
    /// in a directory we own.
    static func attachment(
        _ source: BeeperAttachment,
        index: Int,
        messageID: String
    ) -> MessageAttachment {
        let mime = source.mimeType ?? ""
        return MessageAttachment(
            // `id` is usually an mxc:// URL, but it's optional; fall back to a
            // per-message positional id so two attachments never collide.
            id: source.id?.nonEmpty ?? "\(messageID)#\(index)",
            displayName: source.fileName?.nonEmpty ?? defaultName(for: source),
            mimeType: source.mimeType,
            uniformTypeIdentifier: nil,
            byteCount: source.fileSize,
            localURL: nil,
            availability: .downloadRequired,
            isImage: source.type == "img" || mime.hasPrefix("image/")
        )
    }

    private static func defaultName(for source: BeeperAttachment) -> String {
        switch source.type {
        case "img": source.isSticker == true ? "Sticker" : "Image"
        case "video": "Video"
        case "audio": source.isVoiceNote == true ? "Voice message" : "Audio"
        default: "Attachment"
        }
    }

    // MARK: - Search push-down

    /// Maps Trill's parsed operators onto the Server's query parameters so it
    /// narrows before the wire. `is:unread` has **no server equivalent** and is
    /// left to the local predicate, which runs over the results either way.
    static func searchParameters(
        for query: MessageSearchQuery,
        cursor: String?,
        accountIDs: [String]
    ) -> BeeperMessageSearchParameters {
        let filters = query.filters
        var mediaTypes: [String] = []
        if filters.requiresImage { mediaTypes.append("image") }
        if filters.requiresLink { mediaTypes.append("link") }
        if filters.requiresAttachment, mediaTypes.isEmpty { mediaTypes.append("any") }

        return BeeperMessageSearchParameters(
            query: query.text.nonEmpty,
            cursor: cursor,
            limit: query.limit,
            accountIDs: accountIDs,
            chatIDs: query.conversationID.map { [$0.externalGUID] } ?? [],
            chatType: filters.conversationKind.map { $0 == .group ? "group" : "single" },
            sender: senderParameter(filters.sender),
            dateAfter: filters.after.map(iso8601),
            dateBefore: filters.before.map(iso8601),
            mediaTypes: mediaTypes
        )
    }

    private static func senderParameter(_ sender: String?) -> String? {
        guard let sender = sender?.nonEmpty else { return nil }
        // Trill's parser accepts me/you/myself for one's own messages; anything
        // else is passed through as a user id and the local predicate still
        // applies, so a name that isn't an id simply narrows nothing server-side.
        return ["me", "you", "myself"].contains(sender.lowercased()) ? "me" : sender
    }

    // MARK: - Dates

    // `ISO8601DateFormatter` is documented thread-safe and these are configured
    // once and never mutated; building one per call would parse a format
    // description on every message.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The API documents ISO 8601 but is inconsistent about fractional seconds,
    /// so try both rather than dropping a timestamp on the floor.
    static func date(_ value: String?) -> Date? {
        guard let value = value?.nonEmpty else { return nil }
        return isoFractional.date(from: value) ?? isoPlain.date(from: value)
    }

    static func iso8601(_ date: Date) -> String {
        isoPlain.string(from: date)
    }
}

private extension String {
    /// Title-cases a bare bridge type when the Server gives us no display name.
    var capitalizedNetworkName: String {
        isEmpty ? "Chat" : prefix(1).uppercased() + dropFirst()
    }
}
