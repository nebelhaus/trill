import Foundation

protocol MessagesProvider: Sendable {
    var id: ProviderID { get }

    func health() async -> ProviderHealth
    func capabilities() async -> ProviderCapabilities
    func conversations(page: ConversationPageRequest) async throws -> ConversationPage
    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage
    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage
    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error>
    func send(_ request: SendRequest) async throws -> SendOutcome
    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome
    func react(_ request: ReactionRequest) async throws -> ReactionOutcome
    func contactSuggestions(matching term: String) async -> [ContactSuggestion]
    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem]
}

extension MessagesProvider {
    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome {
        .rejected(operationID: request.operationID, reason: .unsupported)
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] { [] }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] { [] }
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
