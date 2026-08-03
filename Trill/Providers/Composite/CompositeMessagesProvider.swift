import Foundation

/// One inbox over several providers.
///
/// Conforms to `MessagesProvider` itself, so `MessagesRepository`,
/// `ConversationModel` and the feature layer keep the seam they already have and
/// need no multi-provider awareness of their own — see
/// `docs/architecture-decisions/0003-provider-aggregation.md`.
///
/// **It never re-qualifies an identifier.** Child `ConversationID`s and
/// `MessageID`s pass through verbatim; the composite's own `ProviderID` exists
/// for protocol conformance and must never reach a domain model. A thread that
/// was `("imessage", guid)` arriving as `("composite", …)` would change its
/// `persistenceKey`, orphaning every pin, draft, folder membership, VIP mark,
/// snooze, archive flag, saved message, read mark and restored tab for it — with
/// no error, just state that quietly isn't there next launch.
actor CompositeMessagesProvider: MessagesProvider {
    nonisolated let id = ProviderID(rawValue: "composite")

    private let children: [any MessagesProvider]
    /// The child whose failures are *blocking*. Its health is reported verbatim,
    /// so the native provider losing Full Disk Access still produces the
    /// full-screen recovery view; every other child degrades to a
    /// `ProviderDegradation` instead of blanking the inbox.
    private let primaryID: ProviderID

    init(children: [any MessagesProvider], primary: ProviderID) {
        precondition(!children.isEmpty, "A composite with no children has nothing to aggregate")
        precondition(
            children.contains { $0.id == primary },
            "The primary provider must be one of the children"
        )
        self.children = children
        primaryID = primary
    }

    nonisolated var eventCursorProviders: [ProviderID] { children.map(\.id) }

    private var primary: any MessagesProvider {
        children.first { $0.id == primaryID } ?? children[0]
    }

    private func child(for provider: ProviderID) throws -> any MessagesProvider {
        guard let match = children.first(where: { $0.id == provider }) else {
            throw MessagesProviderError.wrongProvider
        }
        return match
    }

    // MARK: - Health & capabilities

    func health() async -> ProviderHealth {
        var aggregate = await primary.health()
        var degraded: [ProviderDegradation] = []
        for child in children where child.id != primaryID {
            let state = await child.health().headline
            guard state.availability != .available else { continue }
            degraded.append(ProviderDegradation(providerID: child.id, state: state))
        }
        aggregate.degraded = degraded
        return aggregate
    }

    func health(for conversation: ConversationID) async -> ProviderHealth {
        guard let owner = try? child(for: conversation.provider) else { return await health() }
        return await owner.health(for: conversation)
    }

    /// Union across children — the whole-app answer the health screen and the
    /// live-event gate want. Anything that gates an *action* on a specific
    /// thread must use `capabilities(for:)` instead, or a thread on a read-only
    /// provider inherits a sibling's send capability.
    func capabilities() async -> ProviderCapabilities {
        var values: Set<ProviderCapability> = []
        for child in children {
            values.formUnion(await child.capabilities().values)
        }
        return ProviderCapabilities(values)
    }

    func capabilities(for conversation: ConversationID) async -> ProviderCapabilities {
        guard let owner = try? child(for: conversation.provider) else { return ProviderCapabilities() }
        return await owner.capabilities(for: conversation)
    }

    // MARK: - Merged reads

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        let merged = await CompositePager.page(
            limit: page.limit,
            cursor: page.cursor,
            children: children.map(\.id)
        ) { [children] providerID, childCursor in
            guard let child = children.first(where: { $0.id == providerID }) else {
                throw MessagesProviderError.wrongProvider
            }
            let result = try await child.conversations(
                page: ConversationPageRequest(limit: page.limit, cursor: childCursor)
            )
            return CompositePager.ChildPage(items: result.conversations, nextCursor: result.nextCursor)
        }
        log(merged.failures, operation: "conversations")
        return ConversationPage(
            conversations: merged.items,
            nextCursor: merged.nextCursor,
            failures: merged.failures
        )
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        guard query.hasCriteria else { return MessageSearchPage(messages: [], nextCursor: nil) }
        // A conversation-scoped search has exactly one owner; skip the merge.
        if let scope = query.conversationID {
            return try await child(for: scope.provider).search(query)
        }
        let merged = await CompositePager.page(
            limit: query.limit,
            cursor: query.cursor,
            children: children.map(\.id)
        ) { [children] providerID, childCursor in
            guard let child = children.first(where: { $0.id == providerID }) else {
                throw MessagesProviderError.wrongProvider
            }
            let result = try await child.search(MessageSearchQuery(
                text: query.text,
                conversationID: nil,
                limit: query.limit,
                cursor: childCursor,
                filters: query.filters
            ))
            return CompositePager.ChildPage(items: result.messages, nextCursor: result.nextCursor)
        }
        log(merged.failures, operation: "search")
        return MessageSearchPage(
            messages: merged.items,
            nextCursor: merged.nextCursor,
            failures: merged.failures
        )
    }

    // MARK: - Routed reads

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        try await child(for: conversation.provider).messages(in: conversation, page: page)
    }

    func messages(in conversation: ConversationID, around date: Date, limit: Int) async throws -> DatedMessagePage {
        try await child(for: conversation.provider).messages(in: conversation, around: date, limit: limit)
    }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] {
        try await child(for: conversation.provider).media(in: conversation, limit: limit)
    }

    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample] {
        try await child(for: conversation.provider).statSamples(in: conversation)
    }

    func exportMessages(in conversation: ConversationID) async throws -> [Message] {
        try await child(for: conversation.provider).exportMessages(in: conversation)
    }

    // MARK: - Fanned-out global reads

    /// Resolves saved-message bookmarks that may span providers. Each child is
    /// asked only for its own identifiers, and a child that fails contributes
    /// nothing rather than sinking the whole lookup — these call sites take a
    /// plain array, so a failure is logged, not returned.
    func messages(ids: [MessageID]) async throws -> [Message] {
        let grouped = Dictionary(grouping: ids, by: \.provider)
        var results: [Message] = []
        for child in children {
            guard let wanted = grouped[child.id], !wanted.isEmpty else { continue }
            do {
                results.append(contentsOf: try await child.messages(ids: wanted))
            } catch {
                log([ProviderFailure(providerID: child.id, error: error)], operation: "messages(ids:)")
            }
        }
        return results.sorted { $0.createdAt > $1.createdAt }
    }

    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem] {
        var results: [LibraryItem] = []
        for child in children {
            do {
                results.append(contentsOf: try await child.libraryItems(kind: kind, limit: limit))
            } catch {
                log([ProviderFailure(providerID: child.id, error: error)], operation: "libraryItems")
            }
        }
        return Array(results.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func myMessages(limit: Int) async throws -> [Message] {
        var results: [Message] = []
        for child in children {
            do {
                results.append(contentsOf: try await child.myMessages(limit: limit))
            } catch {
                log([ProviderFailure(providerID: child.id, error: error)], operation: "myMessages")
            }
        }
        return Array(results.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] {
        var seen: Set<String> = []
        var results: [ContactSuggestion] = []
        for child in children {
            for suggestion in await child.contactSuggestions(matching: term)
            where seen.insert(suggestion.handle).inserted {
                results.append(suggestion)
            }
        }
        return results
    }

    // MARK: - Writes

    func send(_ request: SendRequest) async throws -> SendOutcome {
        guard let owner = try? child(for: request.conversationID.provider) else {
            return .rejected(operationID: request.operationID, reason: .invalidRequest)
        }
        return try await owner.send(request)
    }

    /// No conversation to route by — a direct send addresses a raw handle, which
    /// only the native provider knows how to resolve into a thread.
    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome {
        try await primary.sendDirect(request)
    }

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        guard let owner = try? child(for: request.messageID.provider) else {
            return .rejected(operationID: request.operationID, reason: .invalidRequest)
        }
        return try await owner.react(request)
    }

    // MARK: - Merged events

    /// Every child starts fresh. The repository calls `events(resumingFrom:)`
    /// instead, which is where the per-child stored cursors arrive; this exists
    /// only to satisfy the protocol, and there is no single cursor that could
    /// honestly resume more than one child.
    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        await events(resumingFrom: [:])
    }

    /// One child stream per child, merged into one. Each keeps its own cursor and
    /// its own reconnect schedule, so a flaky remote provider reconnecting can't
    /// interrupt the native watcher, and a child that ends cleanly simply stops
    /// contributing. The merged stream finishes only when every child has.
    func events(resumingFrom cursors: [ProviderID: EventCursor]) async -> AsyncThrowingStream<ProviderEvent, Error> {
        let children = children
        return AsyncThrowingStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    for child in children {
                        group.addTask {
                            await Self.pump(child: child, from: cursors[child.id], into: continuation)
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drives one child's stream, resuming from the last cursor it produced and
    /// backing off between reconnects. Errors are absorbed: one child's transport
    /// failing must never finish the merged stream, which would take the healthy
    /// children down with it.
    private static func pump(
        child: any MessagesProvider,
        from cursor: EventCursor?,
        into continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    ) async {
        var resume = cursor
        var attempt = 0
        while !Task.isCancelled {
            do {
                for try await event in await child.events(after: resume) {
                    attempt = 0
                    if let latest = Self.cursor(from: event) { resume = latest }
                    continuation.yield(event)
                }
                return
            } catch {
                AppLog.repository.error(
                    "Child event stream failed provider=\(child.id.rawValue, privacy: .public) error=\(String(describing: type(of: error)), privacy: .public)"
                )
            }
            attempt += 1
            let backoff = min(pow(2.0, Double(attempt)), 30)
            try? await Task.sleep(for: .seconds(backoff))
        }
    }

    private static func cursor(from event: ProviderEvent) -> EventCursor? {
        switch event {
        case let .messageAdded(_, cursor), let .conversationUpdated(_, cursor): cursor
        case .healthChanged, .databaseChanged: nil
        }
    }

    private func log(_ failures: [ProviderFailure], operation: String) {
        for failure in failures {
            AppLog.repository.error(
                "Composite child failed operation=\(operation, privacy: .public) provider=\(failure.providerID.rawValue, privacy: .public) error=\(failure.category, privacy: .public)"
            )
        }
    }
}

extension ProviderHealth {
    /// The one state worth naming when this provider is reported as a
    /// non-blocking degradation of a larger whole: the most degraded dimension,
    /// or `.ready` when nothing is wrong. `notifications` and `contacts` are
    /// excluded — they're optional grants, not provider failures.
    var headline: HealthState {
        let ranked: [HealthState] = [remoteRelay, messagesDatabase, liveEvents, sending].compactMap { $0 }
        func rank(_ state: HealthState) -> Int {
            switch state.availability {
            case .unavailable: 3
            case .limited: 2
            case .unknown: 1
            case .available: 0
            }
        }
        return ranked.max { rank($0) < rank($1) } ?? .ready
    }
}
