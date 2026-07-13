import AppKit
import Foundation

enum ProviderMode: String, CaseIterable, Identifiable, Sendable {
    case fixture
    case messages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixture: "Synthetic Fixtures"
        case .messages: "Messages"
        }
    }
}

enum InboxLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case permissionMissing
    case unsupportedSchema
    case providerUnavailable
    case failed
}

@MainActor
final class InboxModel: ObservableObject {
    @Published private(set) var state: InboxLoadState = .idle
    @Published private(set) var conversations: [Conversation] = []
    @Published var selectedConversationID: ConversationID?
    @Published private(set) var health: ProviderHealth = .fixture
    @Published private(set) var capabilities = ProviderCapabilities()
    @Published private(set) var pinnedIDs: Set<ConversationID> = []
    @Published private(set) var searchResults: [Message] = []
    @Published var isSearchPresented = false
    @Published var isSidebarVisible = true
    @Published private(set) var providerMode: ProviderMode = .fixture
    @Published private(set) var errorSummary: String?

    let conversationModel: ConversationModel
    let composerModel: ComposerModel

    private let database: AppDatabase
    private var repository: MessagesRepository
    private var loadTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private static let providerModeKey = "providerMode"

    init(database: AppDatabase) {
        self.database = database
        let mode = UserDefaults.standard.string(forKey: Self.providerModeKey)
            .flatMap(ProviderMode.init(rawValue:)) ?? .messages
        providerMode = mode
        let repository = MessagesRepository(provider: Self.makeProvider(mode), database: database)
        self.repository = repository
        conversationModel = ConversationModel(repository: repository)
        composerModel = ComposerModel(database: database)
    }

    deinit {
        loadTask?.cancel()
        eventTask?.cancel()
    }

    private static func makeProvider(_ mode: ProviderMode) -> any MessagesProvider {
        switch mode {
        case .fixture: FixtureProvider()
        case .messages: LiveIMessageProvider()
        }
    }

    func load() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            state = .loading
            errorSummary = nil
            health = await repository.health()
            capabilities = await repository.capabilities()

            switch health.messagesDatabase.reason {
            case .permissionMissing:
                state = .permissionMissing
                return
            case .unsupportedSchema:
                state = .unsupportedSchema
                return
            case .manualVerificationRequired, .providerFailure, .databaseMissing:
                state = .providerUnavailable
                return
            default:
                break
            }

            do {
                async let page = repository.conversations(page: ConversationPageRequest(limit: 100))
                async let pins = database.pinnedConversationIDs()
                let (loadedPage, loadedPins) = try await (page, pins)
                pinnedIDs = loadedPins
                conversations = sort(loadedPage.conversations)
                state = conversations.isEmpty ? .empty : .loaded
                updateDockBadge()
                startEventStream()
            } catch is CancellationError {
                return
            } catch {
                AppLog.ui.error("Inbox load failed error=\(String(describing: type(of: error)), privacy: .public)")
                errorSummary = error.localizedDescription
                state = .failed
            }
        }
    }

    func switchProvider(to mode: ProviderMode) {
        guard mode != providerMode else { return }
        providerMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.providerModeKey)
        selectedConversationID = nil
        conversations = []
        eventTask?.cancel()
        conversationModel.clear()
        composerModel.select(nil, capabilities: ProviderCapabilities(), health: .fixture, sendAction: nil)

        repository = MessagesRepository(provider: Self.makeProvider(mode), database: database)
        conversationModel.updateRepository(repository)
        load()
    }

    func select(_ id: ConversationID?) {
        if selectedConversationID != id { selectedConversationID = id }
        guard conversationModel.conversation?.id != id else { return }
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            conversationModel.clear()
            composerModel.select(nil, capabilities: capabilities, health: health, sendAction: nil)
            return
        }
        conversationModel.select(conversation)
        let repository = repository
        composerModel.select(conversation.id, capabilities: capabilities, health: health) { text, attachments in
            try await repository.send(SendRequest(
                operationID: UUID(),
                conversationID: conversation.id,
                text: text,
                attachments: attachments
            ))
        }
    }

    // MARK: - Live events

    private func startEventStream() {
        eventTask?.cancel()
        guard capabilities.supports(.watchLiveEvents) else { return }
        let repository = repository
        eventTask = Task { [weak self] in
            let stream = await repository.eventStream()
            do {
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.handle(event)
                }
            } catch {
                AppLog.ui.error("Event stream ended error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    private func handle(_ event: ProviderEvent) {
        switch event {
        case let .messageAdded(message, _):
            conversationModel.appendLive(message)
        case let .conversationUpdated(conversation, _):
            if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
                conversations[index] = conversation
            } else {
                conversations.append(conversation)
            }
            conversations = sort(conversations)
            if state == .empty { state = .loaded }
            updateDockBadge()
        case let .healthChanged(updated):
            health = updated
        }
    }

    func togglePin(_ id: ConversationID) {
        let shouldPin = !pinnedIDs.contains(id)
        if shouldPin { pinnedIDs.insert(id) } else { pinnedIDs.remove(id) }
        conversations = sort(conversations)
        Task {
            do {
                try await database.setPinned(shouldPin, conversationID: id)
            } catch {
                AppLog.database.error("Pin persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func search(text: String) async {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        do {
            searchResults = try await repository.search(MessageSearchQuery(text: query, limit: 100)).messages
        } catch {
            searchResults = []
            AppLog.ui.error("Search failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func updateDockBadge() {
        let unread = conversations.compactMap(\.unreadCount).reduce(0, +)
        NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    private func sort(_ values: [Conversation]) -> [Conversation] {
        values.sorted { left, right in
            let leftPinned = pinnedIDs.contains(left.id)
            let rightPinned = pinnedIDs.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            if left.lastActivity != right.lastActivity { return left.lastActivity > right.lastActivity }
            return left.id.id < right.id.id
        }
    }
}

