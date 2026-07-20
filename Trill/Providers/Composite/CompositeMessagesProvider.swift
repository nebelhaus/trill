import Foundation

/// Layers write-backed advanced actions on top of a read-only baseline provider.
///
/// Every read, search, event, and text-send call forwards **unchanged** to the
/// `base` provider (`LiveIMessageProvider`) — so the vetted read-only `chat.db`
/// path stays the live read surface and nothing routes reads through the
/// write-capable library. Only `react(_:)` is delegated to `PlatformWriteBackend`,
/// which drives the tapback through platform-imessage's `PlatformAPI`.
///
/// The composite advertises `.sendStandardReactions` on top of the base's
/// capabilities and fills in `ProviderHealth.advancedActions` from the backend's
/// Accessibility probe. Actual tapback availability is then gated by
/// `CapabilityGate.canReact` (capability AND that health dimension) — the same
/// capability+health pairing the text composer uses via `canSend`.
///
/// Constructed only when the hidden `platformWritesEnabled` flag is set on a
/// signed, vetted host (see `InboxModel.makeProvider`); otherwise the app uses
/// the plain base provider and this type is never instantiated.
struct CompositeMessagesProvider: MessagesProvider {
    private let base: any MessagesProvider
    private let writeBackend: PlatformWriteBackend

    init(base: any MessagesProvider, writeBackend: PlatformWriteBackend = PlatformWriteBackend()) {
        self.base = base
        self.writeBackend = writeBackend
    }

    // Transport identity is the base's — the composite is the same account/provider,
    // just with extra write reach. IDs minted by the base stay valid.
    var id: ProviderID { base.id }

    // MARK: - Capabilities & health (merged)

    func capabilities() async -> ProviderCapabilities {
        var values = await base.capabilities().values
        values.insert(.sendStandardReactions)
        return ProviderCapabilities(values)
    }

    func health() async -> ProviderHealth {
        var health = await base.health()
        health.advancedActions = await writeBackend.advancedActionsHealth()
        return health
    }

    // MARK: - Write-backed advanced action (delegated)

    func react(_ request: ReactionRequest) async throws -> ReactionOutcome {
        guard request.messageID.provider == id else { throw MessagesProviderError.wrongProvider }
        return await writeBackend.react(
            threadGUID: request.conversationID.externalGUID,
            messageGUID: request.messageID.externalGUID,
            kind: request.kind,
            operationID: request.operationID
        )
    }

    // MARK: - Everything else forwards unchanged to the read-only baseline

    func conversations(page: ConversationPageRequest) async throws -> ConversationPage {
        try await base.conversations(page: page)
    }

    func messages(in conversation: ConversationID, page: MessagePageRequest) async throws -> MessagePage {
        try await base.messages(in: conversation, page: page)
    }

    func messages(in conversation: ConversationID, around date: Date, limit: Int) async throws -> DatedMessagePage {
        try await base.messages(in: conversation, around: date, limit: limit)
    }

    func messages(ids: [MessageID]) async throws -> [Message] {
        try await base.messages(ids: ids)
    }

    func search(_ query: MessageSearchQuery) async throws -> MessageSearchPage {
        try await base.search(query)
    }

    func events(after cursor: EventCursor?) async -> AsyncThrowingStream<ProviderEvent, Error> {
        await base.events(after: cursor)
    }

    func send(_ request: SendRequest) async throws -> SendOutcome {
        try await base.send(request)
    }

    func sendDirect(_ request: DirectSendRequest) async throws -> SendOutcome {
        try await base.sendDirect(request)
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] {
        await base.contactSuggestions(matching: term)
    }

    func media(in conversation: ConversationID, limit: Int) async throws -> [MediaItem] {
        try await base.media(in: conversation, limit: limit)
    }

    func libraryItems(kind: LibraryKind, limit: Int) async throws -> [LibraryItem] {
        try await base.libraryItems(kind: kind, limit: limit)
    }

    func statSamples(in conversation: ConversationID) async throws -> [MessageStatSample] {
        try await base.statSamples(in: conversation)
    }

    func exportMessages(in conversation: ConversationID) async throws -> [Message] {
        try await base.exportMessages(in: conversation)
    }

    func myMessages(limit: Int) async throws -> [Message] {
        try await base.myMessages(limit: limit)
    }
}
