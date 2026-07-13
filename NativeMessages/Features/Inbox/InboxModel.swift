import AppKit
import Foundation

enum ProviderMode: String, CaseIterable, Identifiable, Sendable {
    case fixture
    case platformIMessage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixture: "Synthetic Fixtures"
        case .platformIMessage: "Messages (Safety-gated)"
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

    init(database: AppDatabase) {
        self.database = database
        let repository = MessagesRepository(provider: FixtureProvider(), database: database)
        self.repository = repository
        conversationModel = ConversationModel(repository: repository)
        composerModel = ComposerModel(database: database)
    }

    deinit {
        loadTask?.cancel()
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
        selectedConversationID = nil
        conversations = []
        conversationModel.clear()
        composerModel.select(nil, capabilities: ProviderCapabilities(), health: .fixture)

        let provider: any MessagesProvider
        switch mode {
        case .fixture: provider = FixtureProvider()
        case .platformIMessage: provider = PlatformIMessageProvider()
        }
        repository = MessagesRepository(provider: provider, database: database)
        conversationModel.updateRepository(repository)
        load()
    }

    func select(_ id: ConversationID?) {
        if selectedConversationID != id { selectedConversationID = id }
        guard conversationModel.conversation?.id != id else { return }
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            conversationModel.clear()
            composerModel.select(nil, capabilities: capabilities, health: health)
            return
        }
        conversationModel.select(conversation)
        composerModel.select(conversation.id, capabilities: capabilities, health: health)
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

