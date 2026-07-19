import ApplicationServices
import Foundation

/// Live Messages provider: reads Apple's chat.db directly (always read-only)
/// and sends by driving Messages.app over Apple Events. This replaces the
/// safety-gated platform-imessage adapter — the write risk that gate guarded
/// against (index creation in chat.db) does not exist on either path here.
actor LiveIMessageProvider: MessagesProvider {
    nonisolated let id = ProviderID(rawValue: "imessage")

    private let reader: ChatDatabaseReader
    private let sender: MessagesSender
    private let accessChecker: MessagesDatabaseAccessChecker
    private let contacts: ContactsNameResolver
    private static let appleEpochOffset: TimeInterval = 978_307_200

    init(
        reader: ChatDatabaseReader = ChatDatabaseReader(),
        sender: MessagesSender = MessagesSender(),
        accessChecker: MessagesDatabaseAccessChecker = MessagesDatabaseAccessChecker()
    ) {
        self.reader = reader
        self.sender = sender
        self.accessChecker = accessChecker
        contacts = ContactsNameResolver()
    }

    // MARK: - Health & capabilities

    func health() async -> ProviderHealth {
        await contacts.prepare()
        let databaseState = MessagesDatabaseAccessChecker.health(for: accessChecker.probe())
        let sendingState: HealthState = databaseState.availability == .available
            ? automationHealth()
            : .notRequested
        return await ProviderHealth(
            messagesDatabase: databaseState,
            liveEvents: databaseState.availability == .available ? .ready : .notRequested,
            sending: sendingState,
            contacts: contacts.authorizationHealth,
            notifications: .notRequested,
            remoteRelay: nil
        )
    }

    func capabilities() async -> ProviderCapabilities {
        ProviderCapabilities([
            .readConversations, .readMessages, .search, .watchLiveEvents,
            .sendText, .sendAttachments,
        ])
    }

    // MARK: - Reads

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        await contacts.prepare()
        let chats = try reader.recentChats(limit: page.limit)
        var conversations: [Conversation] = []
        conversations.reserveCapacity(chats.count)
        for chat in chats {
            conversations.append(try await conversation(from: chat))
        }
        return ConversationPage(conversations: conversations, nextCursor: nil)
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let chat = try reader.chat(guid: conversation.externalGUID) else {
            throw MessagesProviderError.unavailable("Conversation no longer exists in chat.db")
        }
        let rows = try reader.messages(
            chatRowID: chat.rowID,
            beforeRowID: page.before.flatMap(Int64.init),
            limit: page.limit
        )
        let messages = try await map(rows: rows, conversationID: conversation, chatRowID: chat.rowID)
        let nextBefore = rows.count == page.limit ? rows.map(\.rowID).min().map(String.init) : nil
        return MessagePage(messages: messages, nextBefore: nextBefore)
    }

    /// One-shot full-thread read for export: a single unbounded row scan, then
    /// one `map` — so reactions and handles are resolved once for the whole
    /// history instead of re-scanned on every page. Turns a multi-second,
    /// dozens-of-round-trips paging loop into one query + one hydration pass.
    func exportMessages(in conversation: ConversationID) async throws -> [Message] {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let chat = try reader.chat(guid: conversation.externalGUID) else {
            throw MessagesProviderError.unavailable("Conversation no longer exists in chat.db")
        }
        let rows = try reader.allMessages(chatRowID: chat.rowID)
        return try await map(rows: rows, conversationID: conversation, chatRowID: chat.rowID)
    }

    func messages(in conversation: ConversationID, around date: Date, limit: Int) async throws -> DatedMessagePage {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let chat = try reader.chat(guid: conversation.externalGUID) else {
            throw MessagesProviderError.unavailable("Conversation no longer exists in chat.db")
        }
        // Resolve the wall-clock date to the ROWID of the first message that late.
        // Nothing that recent → fall back to the newest page with no anchor.
        guard let anchorRowID = try reader.anchorRowID(
            chatRowID: chat.rowID,
            onOrAfterAppleDate: Self.appleNanoseconds(from: date)
        ) else {
            return DatedMessagePage(
                page: try await messages(in: conversation, page: MessagePageRequest(limit: limit)),
                anchor: nil
            )
        }
        // Load the anchor plus a slice of newer context above it, so the jumped-to
        // day lands with room to scroll both ways rather than glued to the bottom.
        let topRowID = try reader.messageRowID(chatRowID: chat.rowID, newerThan: anchorRowID, offset: limit / 3)
        let rows = try reader.messages(
            chatRowID: chat.rowID,
            beforeRowID: topRowID.map { $0 + 1 },
            limit: limit
        )
        let messages = try await map(rows: rows, conversationID: conversation, chatRowID: chat.rowID)
        let nextBefore = rows.count == limit ? rows.map(\.rowID).min().map(String.init) : nil
        let anchorGUID = rows.first { $0.rowID == anchorRowID }?.guid
        return DatedMessagePage(
            page: MessagePage(messages: messages, nextBefore: nextBefore),
            anchor: anchorGUID.map { MessageID(provider: id, externalGUID: $0) }
        )
    }

    func messages(ids: [MessageID]) async throws -> [Message] {
        // Only resolve identifiers that belong to us; foreign-provider IDs are
        // silently dropped (the saved overlay could outlive a provider switch).
        let guids = ids.filter { $0.provider == id }.map(\.externalGUID)
        guard !guids.isEmpty else { return [] }
        let rows = try reader.messages(guids: guids)
        // Group by owning chat so each message maps under its own conversation —
        // the same per-chat resolution `search` uses for cross-thread results.
        let chats = try reader.chats(rowIDs: Array(Set(rows.map(\.chatRowID))))
        var results: [Message] = []
        results.reserveCapacity(rows.count)
        for row in rows {
            guard let chat = chats[row.chatRowID] else { continue }
            let conversationID = ConversationID(provider: id, externalGUID: chat.guid)
            if let message = try await map(rows: [row], conversationID: conversationID, chatRowID: nil).first {
                results.append(message)
            }
        }
        return results
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        guard query.hasCriteria else { return MessageSearchPage(messages: [], nextCursor: nil) }
        // Free text narrows the scan via SQL LIKE. An operator-only query (e.g.
        // `has:image`) has empty text, which matches broadly, so widen the pool
        // to cover a reasonable recent window before the predicate filters it.
        let poolLimit = query.text.isEmpty ? query.limit * 10 : query.limit * 3
        let rows = try reader.searchMessages(term: query.text, limit: poolLimit)
        let chats = try reader.chats(rowIDs: Array(Set(rows.map(\.chatRowID))))
        // Building the full Conversation is what supplies `in:` kind and
        // `is:unread` count; cache it per chat since results cluster into a few.
        var conversationsByChat: [Int64: Conversation] = [:]
        var results: [Message] = []
        for row in rows {
            guard results.count < query.limit else { break }
            guard let chat = chats[row.chatRowID] else { continue }
            let conversationID = ConversationID(provider: id, externalGUID: chat.guid)
            guard let message = try await map(rows: [row], conversationID: conversationID, chatRowID: nil).first
            else { continue }
            let conversation: Conversation
            if let cached = conversationsByChat[row.chatRowID] {
                conversation = cached
            } else {
                conversation = try await self.conversation(from: chat)
                conversationsByChat[row.chatRowID] = conversation
            }
            guard query.matches(message, in: conversation) else { continue }
            results.append(message)
        }
        return MessageSearchPage(messages: results, nextCursor: nil)
    }

    // MARK: - Live events

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        let provider = self
        let databaseURL = reader.databaseURL
        return AsyncThrowingStream { continuation in
            // Coalesce a burst of WAL writes into a single pending wake.
            let (wakes, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let watcher = ChatDatabaseWatcher(databaseURL: databaseURL) { wake.yield(()) }

            let task = Task {
                var lastRowID = (try? await provider.currentMaxRowID()) ?? 0
                watcher.start()
                // Safety net: WAL events are near-instant, but a checkpoint race
                // could drop one. A slow tick bounds worst-case staleness without
                // the constant wakeups of the old 2s poll.
                let ticker = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(15))
                        wake.yield(())
                    }
                }
                defer { ticker.cancel() }

                for await _ in wakes {
                    guard !Task.isCancelled else { break }
                    // Let a commit's WAL writes settle before reading.
                    try? await Task.sleep(for: .milliseconds(120))
                    // Any write may be an in-place edit/tapback/receipt that adds
                    // no new row; signal so the open thread refreshes regardless.
                    continuation.yield(.databaseChanged)
                    do {
                        let (events, newMax) = try await provider.pollEvents(after: lastRowID)
                        lastRowID = newMax
                        for event in events {
                            continuation.yield(event)
                        }
                    } catch {
                        // Transient read failure (e.g. mid-checkpoint) — wait for
                        // the next wake.
                        continue
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                watcher.stop()
                wake.finish()
            }
        }
    }

    private func currentMaxRowID() throws -> Int64 {
        try reader.maxMessageRowID()
    }

    private func pollEvents(after rowID: Int64) async throws -> ([ProviderEvent], Int64) {
        let rows = try reader.messagesAfter(rowID: rowID, limit: 50)
        guard !rows.isEmpty else { return ([], rowID) }
        let newMax = rows.map(\.rowID).max() ?? rowID
        let chats = try reader.chats(rowIDs: Array(Set(rows.map(\.chatRowID))))

        var events: [ProviderEvent] = []
        for row in rows {
            guard let chat = chats[row.chatRowID] else { continue }
            let conversationID = ConversationID(provider: id, externalGUID: chat.guid)
            let cursor = EventCursor(rawValue: String(row.rowID))
            if let message = try await map(rows: [row], conversationID: conversationID, chatRowID: nil).first {
                events.append(.messageAdded(message, cursor: cursor))
            }
        }
        for chat in chats.values {
            guard let refreshed = try reader.chat(guid: chat.guid) else { continue }
            let cursor = EventCursor(rawValue: String(newMax))
            events.append(.conversationUpdated(try await conversation(from: refreshed), cursor: cursor))
        }
        return (events, newMax)
    }

    // MARK: - Send

    func send(_ request: SendRequest) async throws -> SendOutcome {
        guard request.conversationID.provider == id else {
            return .rejected(operationID: request.operationID, reason: .invalidRequest)
        }
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = request.attachments.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !text.isEmpty || !files.isEmpty else {
            return .rejected(operationID: request.operationID, reason: .invalidRequest)
        }
        let guid = request.conversationID.externalGUID
        let directHandle: String? = if let chat = try? reader.chat(guid: guid), !chat.isGroup {
            chat.identifier.nonEmpty
        } else {
            nil
        }

        var anySent = false
        do {
            if !text.isEmpty {
                try sender.send(text: text, chatGUID: guid, directHandle: directHandle)
                anySent = true
            }
            for file in files {
                try sender.sendFile(at: file, chatGUID: guid)
                anySent = true
            }
            return .accepted(operationID: request.operationID)
        } catch let failure as MessagesSender.SendFailure {
            AppLog.repository.error("Send failed detail=\(failure.message, privacy: .public)")
            if anySent {
                // Part of the message reached Messages.app; retrying the whole
                // draft would duplicate it, so surface as unknown.
                return .unknown(operationID: request.operationID, diagnosticCode: "partialSend")
            }
            let reason: UserFacingSendError = failure.message.contains("-1743")
                ? .permissionDenied
                : .providerUnavailable
            return .rejected(operationID: request.operationID, reason: reason)
        }
    }

    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome {
        let handle = request.handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, !text.isEmpty else {
            return .rejected(operationID: request.operationID, reason: .invalidRequest)
        }
        do {
            try sender.send(text: text, toHandle: handle)
            return .accepted(operationID: request.operationID)
        } catch let failure as MessagesSender.SendFailure {
            AppLog.repository.error("Direct send failed detail=\(failure.message, privacy: .public)")
            let reason: UserFacingSendError = failure.message.contains("-1743")
                ? .permissionDenied
                : .providerUnavailable
            return .rejected(operationID: request.operationID, reason: reason)
        }
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        // Messages.app exposes no supported automation surface for tapbacks.
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] {
        await contacts.prepare()
        return await contacts.suggestions(matching: term)
    }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let chat = try reader.chat(guid: conversation.externalGUID) else { return [] }
        return try reader.media(chatRowID: chat.rowID, limit: limit)
            .filter { !Self.isPluginPayload($0.row) }
            .compactMap { entry in
                let attachment = Self.attachment(entry.row)
                guard Self.isMedia(attachment) else { return nil }
                return MediaItem(
                    attachment: attachment,
                    messageID: MessageID(provider: id, externalGUID: entry.messageGUID),
                    createdAt: Self.date(fromAppleNanoseconds: entry.date)
                )
            }
    }

    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample] {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        guard let chat = try reader.chat(guid: conversation.externalGUID) else { return [] }
        return try reader.statSamples(chatRowID: chat.rowID).map {
            MessageStatSample(date: Self.date(fromAppleNanoseconds: $0.date), isFromMe: $0.isFromMe)
        }
    }

    /// Every text message of mine across all chats, for the global writing-style
    /// profile. Deliberately lightweight: the style builder reads only text, date,
    /// and direction, so we skip the per-thread handle/reaction/attachment
    /// hydration `map(rows:…)` does and build minimal outgoing messages straight
    /// from the row text. Read-only, like every other path here.
    func myMessages(limit: Int) async throws -> [Message] {
        let rows = try reader.myMessageRows(limit: limit)
        return rows.compactMap { row -> Message? in
            let text = displayText(text: row.text, body: row.attributedBody)
            guard !text.isEmpty else { return nil }
            let date = Self.date(fromAppleNanoseconds: row.date)
            return Message(
                id: MessageID(provider: id, externalGUID: row.guid),
                conversationID: ConversationID(provider: id, externalGUID: ""),
                providerSequence: String(row.rowID),
                sender: nil,
                isOutgoing: true,
                text: text,
                createdAt: date,
                sentAt: date,
                deliveredAt: nil,
                attachments: [],
                reactions: [],
                replyTo: nil,
                threadOrigin: nil,
                service: .unknown,
                deliveryState: .sent,
                isEdited: row.dateEdited > 0
            )
        }
    }

    private static func isMedia(_ attachment: MessageAttachment) -> Bool {
        attachment.isImage
            || (attachment.mimeType?.hasPrefix("video/") ?? false)
            || (attachment.uniformTypeIdentifier?.contains("movie") ?? false)
    }

    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem] {
        switch kind {
        case .image, .file:
            let wantsMedia = kind == .image
            // Widen the pull: after dropping link-preview payload shells and
            // splitting media vs. other, only a fraction matches the tab.
            return Array(
                try reader.allAttachments(limit: limit * 5)
                    .filter { !Self.isPluginPayload($0.row) }
                    .compactMap { entry -> LibraryItem? in
                        let attachment = Self.attachment(entry.row)
                        guard Self.isMedia(attachment) == wantsMedia else { return nil }
                        return LibraryItem(
                            id: attachment.id,
                            kind: kind,
                            messageID: MessageID(provider: id, externalGUID: entry.messageGUID),
                            conversationID: ConversationID(provider: id, externalGUID: entry.chatGUID),
                            createdAt: Self.date(fromAppleNanoseconds: entry.date),
                            attachment: attachment,
                            url: nil,
                            messageText: nil
                        )
                    }
                    .prefix(limit)
            )
        case .link:
            var items: [LibraryItem] = []
            var seen = Set<String>()
            for entry in try reader.linkCandidates(limit: limit * 6) {
                let text = displayText(text: entry.text, body: entry.body)
                guard !text.isEmpty else { continue }
                let conversationID = ConversationID(provider: id, externalGUID: entry.chatGUID)
                for url in LinkExtractor.urls(in: text) {
                    // One row per (thread, URL): a link reshared within a thread
                    // is noise, but the same link across threads is worth showing.
                    let dedupeKey = conversationID.id + "|" + url.absoluteString
                    guard seen.insert(dedupeKey).inserted else { continue }
                    items.append(LibraryItem(
                        id: entry.guid + "|" + url.absoluteString,
                        kind: .link,
                        messageID: MessageID(provider: id, externalGUID: entry.guid),
                        conversationID: conversationID,
                        createdAt: Self.date(fromAppleNanoseconds: entry.date),
                        attachment: nil,
                        url: url,
                        messageText: text
                    ))
                    if items.count >= limit { return items }
                }
            }
            return items
        case .saved:
            // Saved bookmarks live in the app-owned overlay, not chat.db, so the
            // repository builds this tab from `messages(ids:)`. The provider has
            // no bookmark state of its own.
            return []
        }
    }

    // MARK: - Mapping

    private func conversation(from chat: ChatDatabaseReader.ChatRow) async throws -> Conversation {
        let handleRows = try reader.participants(chatRowID: chat.rowID)
        var participants: [Participant] = []
        participants.reserveCapacity(handleRows.count)
        for handle in handleRows {
            participants.append(await participant(from: handle))
        }

        let preview = try reader.lastMessagePreview(chatRowID: chat.rowID)
        let previewText = displayText(text: preview?.text, body: preview?.body)
        let unread = try reader.unreadCount(chatRowID: chat.rowID)

        // Only threads whose last message is from them can be awaiting a reply;
        // for those, a tapback I left on the trailing inbound run counts as one.
        var reactedToLatestInbound = false
        if preview?.isFromMe == false {
            let tail = Set(try reader.trailingInboundGUIDs(chatRowID: chat.rowID))
            if !tail.isEmpty {
                let mine = Self.latestReactions(try reader.reactions(chatRowID: chat.rowID))
                    .filter(\.isFromMe)
                reactedToLatestInbound = mine.contains { tail.contains($0.targetGUID) }
            }
        }

        let displayName: String
        if let explicit = chat.displayName {
            displayName = explicit
        } else if chat.isGroup {
            let names = participants.prefix(3).map { $0.displayName ?? $0.handle }
            let suffix = participants.count > 3 ? " +\(participants.count - 3)" : ""
            displayName = names.joined(separator: ", ") + suffix
        } else {
            displayName = participants.first.map { $0.displayName ?? $0.handle } ?? chat.identifier
        }

        return Conversation(
            id: ConversationID(provider: id, externalGUID: chat.guid),
            displayName: displayName,
            systemName: chat.displayName,
            participants: participants,
            kind: chat.isGroup ? .group : .direct,
            service: Self.service(from: chat.serviceName),
            lastActivity: Self.date(fromAppleNanoseconds: chat.lastMessageDate),
            lastMessagePreview: previewText.nonEmpty
                ?? ((preview?.hasAttachments ?? false) ? "Attachment" : ""),
            unreadCount: unread > 0 ? unread : nil,
            // No last message (empty thread) counts as "from me" so it never
            // lands in the needs-reply triage view.
            lastMessageFromMe: preview?.isFromMe ?? true,
            reactedToLatestInbound: reactedToLatestInbound
        )
    }

    private func map(
        rows: [ChatDatabaseReader.MessageRow],
        conversationID: ConversationID,
        chatRowID: Int64?
    ) async throws -> [Message] {
        // Reply originators may live outside this page; fetch them so the
        // quote block always has content to show.
        let pageGUIDs = Set(rows.map(\.guid))
        let missingOriginators = Set(rows.compactMap(\.threadOriginatorGUID)).subtracting(pageGUIDs)
        let originatorRows = try reader.messages(guids: Array(missingOriginators))
        let handles = try reader.handles(rowIDs: Array(Set((rows + originatorRows).map(\.handleID))))

        var quotedByGUID: [String: QuotedMessage] = [:]
        for row in rows + originatorRows {
            let senderName: String
            if row.isFromMe {
                senderName = "You"
            } else if let handle = handles[row.handleID] {
                senderName = await contacts.displayName(for: handle.id) ?? handle.id
            } else {
                senderName = "Participant"
            }
            quotedByGUID[row.guid] = QuotedMessage(
                id: MessageID(provider: id, externalGUID: row.guid),
                senderName: senderName,
                text: displayText(text: row.text, body: row.attributedBody),
                hasAttachments: row.hasAttachments
            )
        }

        let attachmentRows = try reader.attachments(messageRowIDs: rows.map(\.rowID))
        let attachmentsByMessage = Dictionary(grouping: attachmentRows, by: \.messageRowID)

        var reactionsByTarget: [String: [MessageReaction]] = [:]
        if let chatRowID {
            let winners = Self.latestReactions(try reader.reactions(chatRowID: chatRowID))
            for reaction in winners {
                let senderName: String
                if reaction.isFromMe {
                    senderName = "You"
                } else if let handle = handles[reaction.handleID] {
                    senderName = await contacts.displayName(for: handle.id) ?? handle.id
                } else {
                    senderName = "Participant"
                }
                guard let mapped = Self.reaction(reaction, senderName: senderName) else { continue }
                reactionsByTarget[reaction.targetGUID, default: []].append(mapped)
            }
        }

        var messages: [Message] = []
        messages.reserveCapacity(rows.count)
        for row in rows.sorted(by: { $0.rowID < $1.rowID }) {
            var sender: Participant?
            if !row.isFromMe, let handle = handles[row.handleID] {
                sender = await participant(from: handle)
            }
            let attachments = (attachmentsByMessage[row.rowID] ?? [])
                .filter { !Self.isPluginPayload($0) }
                .map(Self.attachment)
            let text = displayText(text: row.text, body: row.attributedBody)
            // Skip rows that render as nothing: link-preview payload shells,
            // sticker placements without visible content, etc.
            if text.isEmpty, attachments.isEmpty { continue }
            messages.append(Message(
                id: MessageID(provider: id, externalGUID: row.guid),
                conversationID: conversationID,
                providerSequence: String(row.rowID),
                sender: sender,
                isOutgoing: row.isFromMe,
                text: text,
                createdAt: Self.date(fromAppleNanoseconds: row.date),
                sentAt: row.isFromMe ? Self.date(fromAppleNanoseconds: row.date) : nil,
                deliveredAt: row.isDelivered && row.dateDelivered > 0
                    ? Self.date(fromAppleNanoseconds: row.dateDelivered)
                    : nil,
                attachments: attachments,
                reactions: reactionsByTarget[row.guid] ?? [],
                replyTo: row.threadOriginatorGUID.map { MessageID(provider: id, externalGUID: $0) },
                threadOrigin: row.threadOriginatorGUID.map { MessageID(provider: id, externalGUID: $0) },
                service: Self.service(from: nil, chatGUID: conversationID.externalGUID),
                deliveryState: Self.deliveryState(row),
                readAt: row.isFromMe && row.dateRead > 0 ? Self.date(fromAppleNanoseconds: row.dateRead) : nil,
                isEdited: row.dateEdited > 0,
                quoted: row.threadOriginatorGUID.flatMap { quotedByGUID[$0] }
            ))
        }
        return messages
    }

    private func participant(from handle: ChatDatabaseReader.HandleRow) async -> Participant {
        Participant(
            id: handle.id,
            displayName: await contacts.displayName(for: handle.id),
            handle: handle.id,
            avatarData: await contacts.thumbnail(for: handle.id)
        )
    }

    private func displayText(text: String?, body: Data?) -> String {
        if let text, !text.isEmpty {
            return TypedstreamText.displayText(text)
        }
        guard let body, let extracted = TypedstreamText.extract(from: body) else { return "" }
        return TypedstreamText.displayText(extracted)
    }

    /// Link previews store their payloads as hidden ".pluginPayloadAttachment"
    /// files; they are implementation detail, not user-visible attachments.
    private static func isPluginPayload(_ row: ChatDatabaseReader.AttachmentRow) -> Bool {
        (row.filename ?? row.transferName ?? "").hasSuffix(".pluginPayloadAttachment")
            || row.uti == "com.apple.messages.url.balloonprovider"
    }

    private static func attachment(_ row: ChatDatabaseReader.AttachmentRow) -> MessageAttachment {
        let expandedPath = row.filename.map { NSString(string: $0).expandingTildeInPath }
        let url = expandedPath.map { URL(fileURLWithPath: $0) }
        let exists = expandedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
        let mime = row.mimeType ?? ""
        return MessageAttachment(
            id: row.guid,
            displayName: row.transferName?.nonEmpty
                ?? url?.lastPathComponent
                ?? "Attachment",
            mimeType: row.mimeType,
            uniformTypeIdentifier: row.uti,
            byteCount: row.totalBytes > 0 ? row.totalBytes : nil,
            localURL: exists ? url : nil,
            availability: exists ? .available : .missing,
            isImage: mime.hasPrefix("image/") || (row.uti?.contains("image") ?? false)
        )
    }

    /// Collapses the raw tapback stream to the currently-active reactions.
    ///
    /// Each person holds one tapback "slot" per message for the classic set
    /// (love/like/…), plus one slot per distinct emoji for custom reactions.
    /// A change or removal is recorded as a *new* row — a removal reuses the
    /// add code +1000 (2000→3000). So we key by slot, keep the newest event,
    /// and drop the slot entirely when that newest event is a removal.
    static func latestReactions(
        _ rows: [ChatDatabaseReader.ReactionRow]
    ) -> [ChatDatabaseReader.ReactionRow] {
        func isRemoval(_ kind: Int) -> Bool { kind >= 3000 }
        func slot(_ row: ChatDatabaseReader.ReactionRow) -> String {
            let sender = row.isFromMe ? "me" : String(row.handleID)
            let base = isRemoval(row.kind) ? row.kind - 1000 : row.kind
            let group = base == 2006 ? (row.emoji ?? "custom") : "classic"
            return "\(row.targetGUID)|\(sender)|\(group)"
        }
        var latest: [String: ChatDatabaseReader.ReactionRow] = [:]
        for row in rows {
            let key = slot(row)
            guard let current = latest[key] else { latest[key] = row; continue }
            // Newer wins; on a date tie prefer the add so a simultaneous
            // replace shows the new reaction rather than a stale removal.
            if row.date > current.date
                || (row.date == current.date && !isRemoval(row.kind)) {
                latest[key] = row
            }
        }
        return latest.values.filter { !isRemoval($0.kind) }
    }

    private static func reaction(_ row: ChatDatabaseReader.ReactionRow, senderName: String) -> MessageReaction? {
        let mapping: (ReactionKind, String)? = switch row.kind {
        case 2000: (.love, "❤️")
        case 2001: (.like, "👍")
        case 2002: (.dislike, "👎")
        case 2003: (.laugh, "😂")
        case 2004: (.emphasis, "‼️")
        case 2005: (.question, "❓")
        case 2006: row.emoji.map { (.custom, $0) }
        default: nil
        }
        guard let mapping else { return nil }
        return MessageReaction(
            id: row.guid,
            kind: mapping.0,
            senderDisplayName: senderName,
            glyph: mapping.1,
            isFromMe: row.isFromMe
        )
    }

    private static func deliveryState(_ row: ChatDatabaseReader.MessageRow) -> MessageDeliveryState {
        if row.error != 0 { return .failed }
        if row.isDelivered { return .delivered }
        if row.isFromMe { return row.isSent ? .sent : .pending }
        return .unknown
    }

    private static func date(fromAppleNanoseconds value: Int64) -> Date {
        // chat.db stores nanoseconds since 2001-01-01 on modern macOS.
        Date(timeIntervalSince1970: Double(value) / 1_000_000_000 + appleEpochOffset)
    }

    /// Inverse of `date(fromAppleNanoseconds:)` — a wall-clock date as Apple-epoch
    /// nanoseconds, for date-bounded queries.
    private static func appleNanoseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - appleEpochOffset) * 1_000_000_000)
    }

    private static func service(from serviceName: String?, chatGUID: String? = nil) -> MessageServiceKind {
        let name = serviceName ?? chatGUID?.split(separator: ";").first.map(String.init) ?? ""
        return switch name {
        case "iMessage": .iMessage
        case "SMS": .sms
        case "RCS": .rcs
        default: .unknown
        }
    }

    private func automationHealth() -> HealthState {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS").aeDesc?.pointee else {
            return .ready
        }
        var address = target
        let status = AEDeterminePermissionToAutomateTarget(&address, typeWildCard, typeWildCard, false)
        switch Int(status) {
        case 0, -600, -1744: // allowed, Messages not running, or not yet prompted
            return .ready
        case -1743:
            return HealthState(
                availability: .unavailable,
                reason: .permissionMissing,
                recoverySuggestion: "Allow Native Messages to control Messages in System Settings → Privacy → Automation."
            )
        default:
            return .ready
        }
    }
}
