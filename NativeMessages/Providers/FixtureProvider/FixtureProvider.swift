import Foundation

actor FixtureProvider: MessagesProvider {
    nonisolated let id = ProviderID(rawValue: "fixture")

    private let fixture: FixtureData
    private var continuations: [UUID: AsyncThrowingStream<ProviderEvent, Error>.Continuation] = [:]

    init(fixture: FixtureData = .standard) {
        self.fixture = fixture
    }

    func health() async -> ProviderHealth { .fixture }

    func capabilities() async -> ProviderCapabilities {
        ProviderCapabilities([.readConversations, .readMessages, .search, .watchLiveEvents])
    }

    func conversations(page request: ConversationPageRequest) async throws -> ConversationPage {
        let offset = try Self.offset(from: request.cursor)
        let ordered = fixture.conversations.sorted {
            if $0.lastActivity == $1.lastActivity { return $0.id.id < $1.id.id }
            return $0.lastActivity > $1.lastActivity
        }
        guard offset <= ordered.count else { throw MessagesProviderError.invalidCursor }
        let end = min(offset + request.limit, ordered.count)
        let items = Array(ordered[offset..<end])
        return ConversationPage(
            conversations: items,
            nextCursor: end < ordered.count ? String(end) : nil
        )
    }

    func messages(in conversation: ConversationID, page request: MessagePageRequest) async throws -> MessagePage {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let history = fixture.messages[conversation] else { throw MessagesProviderError.conversationNotFound }
        let alreadyLoaded = try Self.offset(from: request.before)
        guard alreadyLoaded <= history.count else { throw MessagesProviderError.invalidCursor }

        let end = history.count - alreadyLoaded
        let start = max(0, end - request.limit)
        let items = Array(history[start..<end])
        let totalLoaded = alreadyLoaded + items.count
        return MessagePage(messages: items, nextBefore: start > 0 ? String(totalLoaded) : nil)
    }

    func messages(ids: [MessageID]) async throws -> [Message] {
        let wanted = Set(ids)
        return fixture.messages.values.flatMap { $0 }.filter { wanted.contains($0.id) }
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        let offset = try Self.offset(from: query.cursor)
        guard query.hasCriteria else { return MessageSearchPage(messages: [], nextCursor: nil) }

        let conversationsByID = Dictionary(
            uniqueKeysWithValues: fixture.conversations.map { ($0.id, $0) }
        )
        let matches = fixture.messages
            .filter { query.conversationID == nil || $0.key == query.conversationID }
            .flatMap(\.value)
            .filter { query.matches($0, in: conversationsByID[$0.conversationID]) }
            .sorted {
                if $0.createdAt == $1.createdAt { return $0.id.id < $1.id.id }
                return $0.createdAt > $1.createdAt
            }
        guard offset <= matches.count else { throw MessagesProviderError.invalidCursor }
        let end = min(offset + query.limit, matches.count)
        return MessageSearchPage(
            messages: Array(matches[offset..<end]),
            nextCursor: end < matches.count ? String(end) : nil
        )
    }

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        let token = UUID()
        return AsyncThrowingStream { continuation in
            continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let history = fixture.messages[conversation] else { return [] }
        return history.reversed()
            .flatMap { message in
                message.attachments
                    .filter(\.isImage)
                    .map { MediaItem(attachment: $0, messageID: message.id, createdAt: message.createdAt) }
            }
            .prefix(limit)
            .map { $0 }
    }

    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem] {
        let dated = fixture.messages
            .flatMap { conversation, history in history.map { (conversation, $0) } }
            .sorted { $0.1.createdAt > $1.1.createdAt }
        switch kind {
        case .image, .file:
            let wantsMedia = kind == .image
            return Array(
                dated.flatMap { conversation, message in
                    message.attachments.compactMap { attachment -> LibraryItem? in
                        guard attachment.isImage == wantsMedia else { return nil }
                        return LibraryItem(
                            id: attachment.id,
                            kind: kind,
                            messageID: message.id,
                            conversationID: conversation,
                            createdAt: message.createdAt,
                            attachment: attachment,
                            url: nil,
                            messageText: nil
                        )
                    }
                }
                .prefix(limit)
            )
        case .link:
            var items: [LibraryItem] = []
            var seen = Set<String>()
            for (conversation, message) in dated {
                for url in LinkExtractor.urls(in: message.text) {
                    let dedupeKey = conversation.id + "|" + url.absoluteString
                    guard seen.insert(dedupeKey).inserted else { continue }
                    items.append(LibraryItem(
                        id: message.id.id + "|" + url.absoluteString,
                        kind: .link,
                        messageID: message.id,
                        conversationID: conversation,
                        createdAt: message.createdAt,
                        attachment: nil,
                        url: url,
                        messageText: message.text
                    ))
                    if items.count >= limit { return items }
                }
            }
            return items
        case .saved:
            // Bookmarks come from the app-owned overlay via the repository, not
            // from the fixture message set.
            return []
        }
    }

    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample] {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let history = fixture.messages[conversation] else { return [] }
        return history.map { MessageStatSample(date: $0.createdAt, isFromMe: $0.isOutgoing) }
    }

    func emit(_ event: ProviderEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    func finishEvents(throwing error: Error? = nil) {
        for continuation in continuations.values {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
        continuations.removeAll()
    }

    private func removeContinuation(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private static func offset(from cursor: String?) throws -> Int {
        guard let cursor else { return 0 }
        guard let value = Int(cursor), value >= 0 else { throw MessagesProviderError.invalidCursor }
        return value
    }
}

struct FixtureData: Sendable {
    let conversations: [Conversation]
    let messages: [ConversationID: [Message]]

    static let standard = makeStandard()

    /// Whether I've reacted to the trailing run of received messages — the most
    /// recent messages from them, before my last sent one. Mirrors what the live
    /// provider derives from chat.db so the fixtures stay honest.
    private static func iReactedToLatestInbound(_ messages: [Message]) -> Bool {
        messages.reversed()
            .prefix { !$0.isOutgoing }
            .contains { $0.reactions.contains(where: \.isFromMe) }
    }

    private static func makeStandard() -> FixtureData {
        let provider = ProviderID(rawValue: "fixture")
        let base = Date(timeIntervalSince1970: 1_735_689_600)
        let avery = Participant(id: "fixture-avery", displayName: "Avery Chen", handle: "avery@example.invalid")
        let morgan = Participant(id: "fixture-morgan", displayName: "Morgan Reed", handle: "morgan@example.invalid")
        let riley = Participant(id: "fixture-riley", displayName: "Riley Park", handle: "+15550102020")

        let directID = ConversationID(provider: provider, externalGUID: "fixture-direct-imessage")
        let smsID = ConversationID(provider: provider, externalGUID: "fixture-direct-sms")
        let groupID = ConversationID(provider: provider, externalGUID: "fixture-group-weekend")

        var directMessages: [Message] = []
        for index in 0..<96 {
            let outgoing = index.isMultiple(of: 3)
            directMessages.append(
                Message(
                    id: MessageID(provider: provider, externalGUID: "fixture-direct-\(index)"),
                    conversationID: directID,
                    providerSequence: String(index),
                    sender: outgoing ? nil : avery,
                    isOutgoing: outgoing,
                    text: outgoing ? "Synthetic project update \(index)." : "Synthetic reply \(index) for pagination testing.",
                    createdAt: base.addingTimeInterval(Double(index) * 180),
                    sentAt: nil,
                    deliveredAt: nil,
                    attachments: index == 90 ? [
                        MessageAttachment(
                            id: "fixture-image",
                            displayName: "sample-landscape.jpg",
                            mimeType: "image/jpeg",
                            uniformTypeIdentifier: "public.jpeg",
                            byteCount: 245_760,
                            localURL: nil,
                            availability: .available,
                            isImage: true
                        ),
                    ] : [],
                    reactions: index == 91 ? [
                        MessageReaction(id: "fixture-reaction-like", kind: .like, senderDisplayName: "Avery", glyph: "👍"),
                        MessageReaction(id: "fixture-reaction-like-me", kind: .like, senderDisplayName: "You", glyph: "👍", isFromMe: true),
                        MessageReaction(id: "fixture-reaction-laugh", kind: .laugh, senderDisplayName: "Avery", glyph: "😂"),
                    ] : [],
                    replyTo: index == 92 ? MessageID(provider: provider, externalGUID: "fixture-direct-89") : nil,
                    threadOrigin: nil,
                    service: .iMessage,
                    deliveryState: outgoing ? .delivered : .unknown,
                    quoted: index == 92 ? QuotedMessage(
                        id: MessageID(provider: provider, externalGUID: "fixture-direct-89"),
                        senderName: "Avery",
                        text: "Synthetic reply 89 for pagination testing.",
                        hasAttachments: false
                    ) : nil
                )
            )
        }

        var smsMessages: [Message] = []
        for index in 0..<14 {
            let attachments: [MessageAttachment]
            if index == 8 {
                attachments = [
                    MessageAttachment(
                        id: "fixture-missing",
                        displayName: "missing-receipt.pdf",
                        mimeType: "application/pdf",
                        uniformTypeIdentifier: "com.adobe.pdf",
                        byteCount: nil,
                        localURL: nil,
                        availability: .missing,
                        isImage: false
                    ),
                ]
            } else {
                attachments = []
            }

            let message = Message(
                id: MessageID(provider: provider, externalGUID: "fixture-sms-\(index)"),
                conversationID: smsID,
                providerSequence: String(index),
                sender: index.isMultiple(of: 2) ? riley : nil,
                isOutgoing: !index.isMultiple(of: 2),
                text: index == 13 ? "The synthetic SMS example is ready." : "SMS fixture line \(index).",
                createdAt: base.addingTimeInterval(50_000 + Double(index) * 420),
                sentAt: nil,
                deliveredAt: nil,
                attachments: attachments,
                reactions: [],
                replyTo: nil,
                threadOrigin: nil,
                service: .sms,
                deliveryState: .unknown
            )
            smsMessages.append(message)
        }

        var groupMessages: [Message] = []
        for index in 0..<22 {
            let sender: Participant? = index.isMultiple(of: 4) ? nil : (index.isMultiple(of: 2) ? morgan : avery)
            let attachments: [MessageAttachment]
            if index == 12 {
                attachments = [
                    MessageAttachment(
                        id: "fixture-document",
                        displayName: "weekend-plan.txt",
                        mimeType: "text/plain",
                        uniformTypeIdentifier: "public.plain-text",
                        byteCount: 1_024,
                        localURL: nil,
                        availability: .available,
                        isImage: false
                    ),
                ]
            } else {
                attachments = []
            }
            let reactions: [MessageReaction]
            switch index {
            case 18:
                reactions = [MessageReaction(id: "fixture-reaction-love", kind: .love, senderDisplayName: "Morgan", glyph: "❤️")]
            case 21:
                // I tapped back on the last received message, so this thread
                // reads as answered and drops out of needs-reply triage.
                reactions = [MessageReaction(id: "fixture-reaction-mine", kind: .like, senderDisplayName: "You", glyph: "👍", isFromMe: true)]
            default:
                reactions = []
            }
            let replyTo = index == 19
                ? MessageID(provider: provider, externalGUID: "fixture-group-17")
                : nil

            let message = Message(
                id: MessageID(provider: provider, externalGUID: "fixture-group-\(index)"),
                conversationID: groupID,
                providerSequence: String(index),
                sender: sender,
                isOutgoing: sender == nil,
                text: {
                    switch index {
                    case 21: return "All synthetic plans are confirmed."
                    // A message with a real URL so `has:link` has something to
                    // narrow to in fixture mode and in tests.
                    case 6: return "Group fixture message 6 — details at https://example.invalid/plans"
                    default: return "Group fixture message \(index)."
                    }
                }(),
                createdAt: base.addingTimeInterval(90_000 + Double(index) * 240),
                sentAt: nil,
                deliveredAt: nil,
                attachments: attachments,
                reactions: reactions,
                replyTo: replyTo,
                threadOrigin: nil,
                service: .iMessage,
                deliveryState: sender == nil ? .sent : .unknown,
                quoted: index == 19 ? QuotedMessage(
                    id: MessageID(provider: provider, externalGUID: "fixture-group-17"),
                    senderName: "Avery Chen",
                    text: "Group fixture message 17.",
                    hasAttachments: false
                ) : nil
            )
            groupMessages.append(message)
        }

        let conversations = [
            Conversation(
                id: groupID,
                displayName: "Weekend Plans",
                systemName: nil,
                participants: [avery, morgan, riley],
                kind: .group,
                service: .iMessage,
                lastActivity: groupMessages.last!.createdAt,
                lastMessagePreview: groupMessages.last!.text,
                unreadCount: 4,
                lastMessageFromMe: groupMessages.last!.isOutgoing,
                reactedToLatestInbound: iReactedToLatestInbound(groupMessages)
            ),
            Conversation(
                id: smsID,
                displayName: "Riley Park",
                systemName: nil,
                participants: [riley],
                kind: .direct,
                service: .sms,
                lastActivity: smsMessages.last!.createdAt,
                lastMessagePreview: smsMessages.last!.text,
                unreadCount: 0,
                lastMessageFromMe: smsMessages.last!.isOutgoing,
                reactedToLatestInbound: iReactedToLatestInbound(smsMessages)
            ),
            Conversation(
                id: directID,
                displayName: "Avery Chen",
                systemName: nil,
                participants: [avery],
                kind: .direct,
                service: .iMessage,
                lastActivity: directMessages.last!.createdAt,
                lastMessagePreview: directMessages.last!.text,
                unreadCount: 2,
                lastMessageFromMe: directMessages.last!.isOutgoing,
                reactedToLatestInbound: iReactedToLatestInbound(directMessages)
            ),
        ]

        return FixtureData(
            conversations: conversations,
            messages: [directID: directMessages, smsID: smsMessages, groupID: groupMessages]
        )
    }
}
