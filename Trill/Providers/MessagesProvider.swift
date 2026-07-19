import Foundation

protocol MessagesProvider: Sendable {
    var id: ProviderID { get }

    func health() async -> ProviderHealth
    func capabilities() async -> ProviderCapabilities
    func conversations(page: ConversationPageRequest) async throws -> ConversationPage
    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage
    /// Loads a window of messages centered on `date` for the "jump to date"
    /// scrubber, resolving the date to a paging position server-side so a leap
    /// into deep history is one query, not dozens of backward pages.
    func messages(in conversation: ConversationID, around date: Date, limit: Int) async throws -> DatedMessagePage
    /// Resolves specific messages by identity, across any conversation. Backs the
    /// saved-messages library tab, which stores only `MessageID`s and needs their
    /// content on demand. Missing IDs are simply absent from the result.
    func messages(ids: [MessageID]) async throws -> [Message]
    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage
    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error>
    func send(_ request: SendRequest) async throws -> SendOutcome
    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome
    func react(_ request: ReactionRequest) async throws -> ReactionOutcome
    func contactSuggestions(matching term: String) async -> [ContactSuggestion]
    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem]
    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem]
    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample]
    func exportMessages(in conversation: ConversationID) async throws -> [Message]
    /// My own text messages across *every* conversation, newest-first, bounded by
    /// `limit`. Backs the global writing-style profile: only outgoing text is
    /// needed, so providers can skip the per-thread handle/reaction hydration.
    func myMessages(limit: Int) async throws -> [Message]
}

extension MessagesProvider {
    /// Default: providers that can't resolve a date to a position fall back to the
    /// newest page with no anchor, so "jump to date" degrades to a plain reload.
    func messages(in conversation: ConversationID, around date: Date, limit: Int) async throws -> DatedMessagePage {
        let page = try await messages(in: conversation, page: MessagePageRequest(limit: limit))
        return DatedMessagePage(page: page, anchor: nil)
    }

    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] { [] }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] { [] }

    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem] { [] }

    func messages(ids: [MessageID]) async throws -> [Message] { [] }

    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample] { [] }

    func myMessages(limit: Int) async throws -> [Message] { [] }

    /// Full-thread read for conversation export. The default pages through
    /// `messages(in:page:)` until the history is exhausted — correct for any
    /// provider. Providers with a cheaper one-shot read (the live chat.db
    /// reader) override this to avoid the per-page round-trips.
    func exportMessages(in conversation: ConversationID) async throws -> [Message] {
        var collected: [MessageID: Message] = [:]
        var before: String?
        var pagesRemaining = 1_000
        repeat {
            let page = try await messages(in: conversation, page: MessagePageRequest(limit: 200, before: before))
            for message in page.messages { collected[message.id] = message }
            before = page.nextBefore
            pagesRemaining -= 1
        } while before != nil && pagesRemaining > 0
        return collected.values.sorted { left, right in
            left.createdAt == right.createdAt ? left.id.id < right.id.id : left.createdAt < right.createdAt
        }
    }
}

enum MessagesProviderError: LocalizedError, Sendable {
    case wrongProvider
    case conversationNotFound
    case invalidCursor
    case unsupportedSchema
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .wrongProvider: "The identifier belongs to another provider."
        case .conversationNotFound: "The conversation could not be found."
        case .invalidCursor: "The provider cursor is invalid."
        case .unsupportedSchema: "This Messages database schema is not supported."
        case .unavailable: "The Messages provider is unavailable."
        }
    }
}
