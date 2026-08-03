import Foundation

/// Read-only `MessagesProvider` over a headless Beeper Server's REST API.
///
/// **Read-only is a scope decision, not a limitation of the API.** The Server
/// offers `markRead`, `archive`, drafts, reactions, sends and chat creation;
/// every one of them is out of scope here and gated behind per-account
/// capability checks in a later phase. `send`/`react` reject rather than
/// silently no-op, so nothing can present an unsupported action as success.
///
/// Unrelated to `Providers/PlatformIMessageProvider/`, which is Beeper's *local
/// iMessage library* (`platform-imessage`) and touches `chat.db` directly. This
/// one is an HTTP client and touches no database at all.
actor BeeperProvider: MessagesProvider {
    nonisolated let id = BeeperMapper.providerID

    private let source: any BeeperConfigurationProviding
    private let session: URLSession?
    private let assets: BeeperAssetCache
    private let pollInterval: Duration

    /// `accountID` → service identity, for the accounts we're willing to show.
    /// Refreshed on demand; `nil` means "not fetched yet", which is distinct
    /// from "fetched and empty".
    private var services: [String: ServiceIdentity]?
    /// Last transport failure category, for the health row. Non-content.
    private var lastFailure: String?

    init(
        source: any BeeperConfigurationProviding = BeeperConfigurationSource(),
        session: URLSession? = nil,
        assets: BeeperAssetCache = BeeperAssetCache(),
        pollInterval: Duration = .seconds(15)
    ) {
        self.source = source
        self.session = session
        self.assets = assets
        self.pollInterval = pollInterval
    }

    // MARK: - Configuration

    private func client() throws -> BeeperClient {
        guard let configuration = ((try? source.current()) ?? nil) else {
            throw BeeperClient.Failure.notConfigured
        }
        return BeeperClient(configuration: configuration, session: session)
    }

    /// The account allowlist we send with every list/search call. Beeper's own
    /// iMessage accounts are excluded at *request* time — fetching and then
    /// discarding them would corrupt page sizes as well as showing threads twice.
    private func visibleAccountIDs() async throws -> [String] {
        try await Array(serviceMap().keys).sorted()
    }

    private func serviceMap() async throws -> [String: ServiceIdentity] {
        if let services { return services }
        let accounts = try await client().accounts()
        let map = BeeperMapper.serviceIdentities(for: accounts)
        services = map
        return map
    }

    /// The identity for a chat's account. A chat whose account we don't know
    /// (added since our last refresh, or filtered) has no identity, which is what
    /// keeps a stray iMessage chat from rendering.
    private func service(for chat: BeeperChat) async -> ServiceIdentity? {
        guard let map = try? await serviceMap() else { return nil }
        return map[chat.accountID]
    }

    // MARK: - Health & capabilities

    func health() async -> ProviderHealth {
        let relay: HealthState
        do {
            guard let configuration = try source.current() else {
                relay = HealthState(
                    availability: .unknown,
                    reason: .notRequested,
                    recoverySuggestion: "Add a Beeper access token in Settings to include Beeper networks."
                )
                return health(relay: relay)
            }
            _ = configuration
            _ = try await client().info()
            lastFailure = nil
            relay = .ready
        } catch let failure as BeeperClient.Failure {
            lastFailure = failure.category
            relay = HealthState(
                availability: .unavailable,
                reason: failure.isAuthentication ? .permissionMissing : .providerFailure,
                recoverySuggestion: failure.isAuthentication
                    ? "The Beeper access token was rejected. Paste a fresh one from Beeper → Settings → Advanced → API."
                    : "Trill could not reach the Beeper Server. Check that it is running."
            )
        } catch {
            lastFailure = String(describing: type(of: error))
            relay = HealthState(
                availability: .unavailable,
                reason: .providerFailure,
                recoverySuggestion: "Trill could not reach the Beeper Server."
            )
        }
        return health(relay: relay)
    }

    /// `ProviderHealth`'s first field is literally `messagesDatabase`, and this
    /// provider has no database — so it reports `.notRequested` there rather than
    /// jamming an HTTP failure into a field named after a database, and puts the
    /// real state in `remoteRelay`, which is the dimension that actually fits. The
    /// composite reads `headline`, which prefers `remoteRelay`, and lists this
    /// provider as a *degradation* rather than folding it into anything blocking.
    private func health(relay: HealthState) -> ProviderHealth {
        ProviderHealth(
            messagesDatabase: .notRequested,
            liveEvents: relay.availability == .available ? .ready : relay,
            // No send path exists in this phase, so sending is disabled by
            // construction rather than by a capability the UI might misread.
            sending: .disabled,
            contacts: relay.availability == .available ? .ready : .notRequested,
            notifications: .notRequested,
            remoteRelay: relay
        )
    }

    func capabilities() async -> ProviderCapabilities {
        ProviderCapabilities([.readConversations, .readMessages, .search, .watchLiveEvents])
    }

    /// Beeper reports capabilities per *chat*, which is the case that motivated
    /// `capabilities(for:)` existing at all. The write-side capabilities it
    /// advertises (`edit`, `reaction`, `reply`, `delete`) are deliberately not
    /// translated yet: this phase has no write path, and advertising one the
    /// provider can't honor is how an action gets offered and then fails.
    func capabilities(for conversation: ConversationID) async -> ProviderCapabilities {
        await capabilities()
    }

    // MARK: - Conversations

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        let client = try client()
        let allowed = try await visibleAccountIDs()
        guard !allowed.isEmpty else { return ConversationPage(conversations: [], nextCursor: nil) }
        let response = try await client.chats(cursor: page.cursor, accountIDs: allowed)
        var conversations: [Conversation] = []
        conversations.reserveCapacity(response.items.count)
        for chat in response.items {
            // Second line of defence on the iMessage exclusion: the request-time
            // allowlist covers this call, but not the event stream.
            guard let service = await service(for: chat) else { continue }
            conversations.append(BeeperMapper.conversation(chat, service: service))
        }
        return ConversationPage(
            conversations: conversations,
            nextCursor: response.hasMore ? response.oldestCursor : nil
        )
    }

    // MARK: - Messages

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        let client = try client()
        let response = try await client.messages(chatID: conversation.externalGUID, cursor: page.before)
        let service = await serviceForConversation(conversation, in: response.items)
        let messages = map(response.items, conversationID: conversation, service: service)
        return MessagePage(
            messages: messages,
            nextBefore: response.hasMore ? response.oldestCursor : nil
        )
    }

    func messages(ids: [MessageID]) async throws -> [Message] {
        // The API resolves a message only *within* a chat
        // (`GET /v1/chats/{chatID}/messages/{messageID}`), and a bare `MessageID`
        // doesn't carry its chat. Rather than guess, this returns nothing and the
        // saved-messages tab simply omits Beeper bookmarks until §3 stores the
        // owning chat alongside them.
        []
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        guard query.hasCriteria else { return MessageSearchPage(messages: [], nextCursor: nil) }
        let client = try client()
        let allowed = try await visibleAccountIDs()
        guard !allowed.isEmpty else { return MessageSearchPage(messages: [], nextCursor: nil) }
        let response = try await client.searchMessages(
            BeeperMapper.searchParameters(for: query, cursor: query.cursor, accountIDs: allowed)
        )
        let map = try await serviceMap()
        var results: [Message] = []
        for source in response.items {
            guard BeeperMapper.isRenderable(source),
                  let chatID = source.chatID?.nonEmpty,
                  let accountID = source.accountID,
                  let service = map[accountID]
            else { continue }
            results.append(BeeperMapper.message(
                source,
                conversationID: ConversationID(provider: id, externalGUID: chatID),
                service: service
            ))
        }
        // `is:unread` has no server equivalent, and the rest of the operators are
        // pushed down but not guaranteed exhaustive, so the same local predicate
        // every other provider applies runs over the results too.
        let filtered = results.filter { query.matches($0, in: nil) }
        return MessageSearchPage(
            messages: filtered,
            nextCursor: response.hasMore ? response.oldestCursor : nil
        )
    }

    // MARK: - Media

    /// The gallery is the one read that materializes bytes, and it's bounded by
    /// `limit`. Paging a thread deliberately does *not* fetch attachments: that
    /// would turn one scroll into dozens of downloads.
    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] {
        guard conversation.provider == id else { throw MessagesProviderError.wrongProvider }
        let client = try client()
        let response = try await client.messages(chatID: conversation.externalGUID, cursor: nil)
        let service = await serviceForConversation(conversation, in: response.items)
        var items: [MediaItem] = []
        for source in response.items.reversed() {
            guard BeeperMapper.isRenderable(source) else { continue }
            let message = BeeperMapper.message(source, conversationID: conversation, service: service)
            for (index, attachment) in message.attachments.enumerated() where attachment.isImage {
                guard items.count < limit else { return items }
                var localURL: URL?
                if let remoteID = source.attachments?[safe: index]?.id {
                    localURL = await assets.localURL(
                        for: remoteID,
                        mimeType: attachment.mimeType,
                        using: client
                    )
                }
                items.append(MediaItem(
                    attachment: MessageAttachment(
                        id: attachment.id,
                        displayName: attachment.displayName,
                        mimeType: attachment.mimeType,
                        uniformTypeIdentifier: attachment.uniformTypeIdentifier,
                        byteCount: attachment.byteCount,
                        localURL: localURL,
                        availability: localURL == nil ? .downloadRequired : .available,
                        isImage: attachment.isImage
                    ),
                    messageID: message.id,
                    createdAt: message.createdAt
                ))
            }
        }
        return items
    }

    // MARK: - Contacts

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, let client = try? client() else { return [] }
        guard let accounts = try? await visibleAccountIDs() else { return [] }
        var seen: Set<String> = []
        var results: [ContactSuggestion] = []
        for accountID in accounts.prefix(8) {
            guard let page = try? await client.contacts(
                accountID: accountID,
                query: trimmed,
                limit: 10
            ) else { continue }
            for user in page.items {
                guard let suggestion = BeeperMapper.contactSuggestion(user),
                      seen.insert(suggestion.handle).inserted
                else { continue }
                results.append(suggestion)
            }
        }
        return results
    }

    // MARK: - Writes (all refused in this phase)

    func send(_ request: SendRequest) async throws -> SendOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    // MARK: - Events

    /// REST polling. The Server exposes a WebSocket (`endpoints.ws_events`) but
    /// it is experimental, and a polling fallback has to exist anyway — so this
    /// phase polls and a later one adds the socket *in front of* this, not
    /// instead of it.
    ///
    /// The cursor is the newest `lastActivity` we've emitted for. On resume, only
    /// chats that moved past it are examined, so a relaunch doesn't replay the
    /// whole list.
    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        let provider = self
        let interval = pollInterval
        return AsyncThrowingStream { continuation in
            let task = Task {
                var watermark = BeeperMapper.date(cursor?.rawValue) ?? .distantPast
                while !Task.isCancelled {
                    do {
                        let (events, advanced) = try await provider.poll(since: watermark)
                        watermark = advanced
                        for event in events { continuation.yield(event) }
                    } catch is CancellationError {
                        break
                    } catch {
                        // A transient outage is not the end of the stream: the
                        // composite would otherwise back off and reconnect this
                        // child for no reason. Report health and keep polling.
                        continuation.yield(.healthChanged(await provider.health()))
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func poll(since watermark: Date) async throws -> ([ProviderEvent], Date) {
        let client = try client()
        let allowed = try await visibleAccountIDs()
        guard !allowed.isEmpty else { return ([], watermark) }
        let response = try await client.chats(cursor: nil, accountIDs: allowed)
        var events: [ProviderEvent] = []
        var newest = watermark

        for chat in response.items {
            guard let activity = BeeperMapper.date(chat.lastActivity), activity > watermark else { continue }
            guard let service = await service(for: chat) else { continue }
            newest = max(newest, activity)
            let cursor = EventCursor(rawValue: BeeperMapper.iso8601(activity))
            events.append(.conversationUpdated(
                BeeperMapper.conversation(chat, service: service),
                cursor: cursor
            ))
            // The chat's own preview is the new message, so a normal tick costs
            // one request rather than one per changed chat.
            if let preview = chat.preview, BeeperMapper.isRenderable(preview) {
                events.append(.messageAdded(
                    BeeperMapper.message(
                        preview,
                        conversationID: ConversationID(provider: id, externalGUID: chat.id),
                        service: service
                    ),
                    cursor: cursor
                ))
            }
        }
        return (events, newest)
    }

    // MARK: - Helpers

    private func serviceForConversation(
        _ conversation: ConversationID,
        in messages: [BeeperMessage]
    ) async -> ServiceIdentity {
        guard let map = try? await serviceMap(),
              let accountID = messages.compactMap(\.accountID).first,
              let service = map[accountID]
        else { return .unknown }
        return service
    }

    private func map(
        _ sources: [BeeperMessage],
        conversationID: ConversationID,
        service: ServiceIdentity
    ) -> [Message] {
        // Reply parents are frequently inside the same page; hydrate the quote
        // from there so the block has content without a second round-trip.
        var quotable: [String: BeeperMessage] = [:]
        for source in sources { quotable[source.id] = source }

        return sources
            .filter(BeeperMapper.isRenderable)
            .map { source in
                BeeperMapper.message(
                    source,
                    conversationID: conversationID,
                    service: service,
                    quoted: source.linkedMessageID
                        .flatMap { quotable[$0] }
                        .map(BeeperMapper.quotedMessage)
                )
            }
            // The API returns newest-first; the timeline wants oldest-first, the
            // same order every other provider hands back.
            .sorted { left, right in
                let leftKey = left.providerSequence ?? ""
                let rightKey = right.providerSequence ?? ""
                if leftKey != rightKey { return leftKey < rightKey }
                return left.createdAt < right.createdAt
            }
    }
}

private extension BeeperClient.Failure {
    var isAuthentication: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
