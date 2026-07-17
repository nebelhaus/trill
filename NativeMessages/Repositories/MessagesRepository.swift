import Foundation

actor ProviderEventDeduplicator {
    private var messageIDs: Set<MessageID> = []

    func shouldAccept(_ event: ProviderEvent) -> Bool {
        switch event {
        case let .messageAdded(message, _):
            return messageIDs.insert(message.id).inserted
        case .conversationUpdated, .healthChanged, .databaseChanged:
            return true
        }
    }
}

actor MessagesRepository {
    private let provider: any MessagesProvider
    private let database: AppDatabase
    private let eventDeduplicator = ProviderEventDeduplicator()

    init(provider: any MessagesProvider, database: AppDatabase) {
        self.provider = provider
        self.database = database
    }

    var providerID: ProviderID { provider.id }

    func health() async -> ProviderHealth {
        await provider.health()
    }

    func capabilities() async -> ProviderCapabilities {
        await provider.capabilities()
    }

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        let clock = ContinuousClock()
        let start = clock.now
        let page = try await provider.conversations(page: page)
        let duration = start.duration(to: clock.now)
        AppLog.repository.info("Loaded conversation page count=\(page.conversations.count, privacy: .public) duration=\(String(describing: duration), privacy: .public)")
        return page
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await provider.messages(in: conversation, page: page)
        let duration = start.duration(to: clock.now)
        AppLog.repository.info("Loaded message page count=\(result.messages.count, privacy: .public) duration=\(String(describing: duration), privacy: .public)")
        return result
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        let outcome = try await provider.send(request)
        AppLog.repository.info("Send completed operation=\(request.operationID, privacy: .public)")
        return outcome
    }

    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome {
        let outcome = try await provider.sendDirect(request)
        AppLog.repository.info("Direct send completed operation=\(request.operationID, privacy: .public)")
        return outcome
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] {
        await provider.contactSuggestions(matching: term)
    }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] {
        try await provider.media(in: conversation, limit: limit)
    }

    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem] {
        // The saved tab is assembled here rather than in the provider: bookmarks
        // live in the app-owned overlay (only the repository holds `database`),
        // and their content is resolved through the provider by identity. Newest
        // message first, mirroring the other tabs' ordering.
        guard kind == .saved else {
            return try await provider.libraryItems(kind: kind, limit: limit)
        }
        let ids = try await database.savedMessageIDs()
        guard !ids.isEmpty else { return [] }
        let messages = try await provider.messages(ids: Array(ids))
        return messages
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map(LibraryItem.init(saved:))
    }

    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample] {
        try await provider.statSamples(in: conversation)
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        let result = try await provider.search(query)
        AppLog.repository.info("Search completed count=\(result.messages.count, privacy: .public)")
        return result
    }

    func eventStream() async -> AsyncThrowingStream<ProviderEvent, Error> {
        let storedCursor = try? await database.cursor(providerID: provider.id)
        let upstream = await provider.events(after: storedCursor)
        let database = database
        let providerID = provider.id
        let deduplicator = eventDeduplicator

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        guard await deduplicator.shouldAccept(event) else { continue }
                        if let cursor = Self.cursor(from: event) {
                            try await database.saveCursor(cursor, providerID: providerID)
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func cursor(from event: ProviderEvent) -> EventCursor? {
        switch event {
        case let .messageAdded(_, cursor), let .conversationUpdated(_, cursor): cursor
        case .healthChanged, .databaseChanged: nil
        }
    }
}
