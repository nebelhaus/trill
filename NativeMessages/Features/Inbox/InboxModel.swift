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

/// Which slice of the conversation list the sidebar shows. These are mutually
/// exclusive views of the same list, not composable flags — picking one clears
/// the others, mirroring how a mail client's mailbox selection works.
enum InboxFilter: String, Sendable {
    /// Every conversation, newest first.
    case all
    /// Only threads with unread messages from them.
    case unread
    /// Triage view: threads whose last message is from them and unanswered.
    case needsReply
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
    /// User-defined folders (local overlay), sidebar order. See `Folder`.
    @Published private(set) var folders: [Folder] = []
    /// folderID → the conversations filed under it. One dictionary serves both
    /// the sidebar counts and the per-conversation membership checkmarks.
    @Published private(set) var folderMembers: [String: Set<ConversationID>] = [:]
    /// Active folder scope for the sidebar. `nil` = All Messages. Applied before
    /// the `filter` axis in `visibleConversations`, and persisted across launches
    /// (validated against existing folders on load, since a folder can be deleted).
    @Published var selectedFolderID: String? = UserDefaults.standard.string(forKey: InboxModel.selectedFolderKey) {
        didSet {
            UserDefaults.standard.set(selectedFolderID, forKey: InboxModel.selectedFolderKey)
        }
    }
    /// chat.db is read-only, so opening a thread can't mark it read upstream.
    /// This overlay hides a thread's badge locally once viewed, until a
    /// message newer than the viewing time arrives (or Messages.app syncs).
    @Published private(set) var clearedUnreadAt: [ConversationID: Date] = [:]
    @Published private(set) var searchResults: [Message] = []
    @Published var isSearchPresented = false
    @Published var isPalettePresented = false {
        didSet {
            // Reset the palette to a clean slate each time it opens.
            if isPalettePresented, !oldValue {
                paletteQuery = ""
                paletteSelection = 0
            }
        }
    }
    /// Command-palette query/selection live on the model so they reset cleanly
    /// each time it opens (see `isPalettePresented`) and give the view's
    /// keyboard handlers a single source of truth to read and mutate.
    @Published var paletteQuery = ""
    @Published var paletteSelection = 0
    /// Prefill handed from the command palette's "Search messages…" row so the
    /// full-text overlay opens already carrying what the user typed.
    @Published var searchSeed: String?
    @Published var isComposePresented = false
    /// Drives the create/edit folder sheet. Set from the sidebar's folder rows,
    /// a conversation's Folders menu, or the command palette. `nil` = closed.
    @Published var folderEditor: FolderEditorMode?
    @Published var isSidebarVisible = true
    /// Active sidebar filter, persisted across launches. Migrates the legacy
    /// `showsUnreadOnly` bool the first time so an existing unread-only view is
    /// preserved. `showsUnreadOnly` / `showsNeedsReplyOnly` are convenience
    /// toggles over this single source of truth.
    @Published var filter: InboxFilter = InboxModel.loadPersistedFilter() {
        didSet { UserDefaults.standard.set(filter.rawValue, forKey: InboxModel.filterKey) }
    }

    var showsUnreadOnly: Bool {
        get { filter == .unread }
        set { filter = newValue ? .unread : .all }
    }

    var showsNeedsReplyOnly: Bool {
        get { filter == .needsReply }
        set { filter = newValue ? .needsReply : .all }
    }
    @Published private(set) var providerMode: ProviderMode = .fixture
    @Published private(set) var errorSummary: String?

    let conversationModel: ConversationModel
    let composerModel: ComposerModel

    private let database: AppDatabase
    private let notifications = NotificationCoordinator()
    private var repository: MessagesRepository
    private var loadTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private static let providerModeKey = "providerMode"
    private static let filterKey = "inboxFilter"
    private static let selectedFolderKey = "selectedFolderID"

    private static func loadPersistedFilter() -> InboxFilter {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: filterKey), let stored = InboxFilter(rawValue: raw) {
            return stored
        }
        // One-time migration from the pre-triage unread-only bool.
        return defaults.bool(forKey: "showsUnreadOnly") ? .unread : .all
    }

    init(database: AppDatabase) {
        self.database = database
        let mode = UserDefaults.standard.string(forKey: Self.providerModeKey)
            .flatMap(ProviderMode.init(rawValue:)) ?? .messages
        providerMode = mode
        let repository = MessagesRepository(provider: Self.makeProvider(mode), database: database)
        self.repository = repository
        conversationModel = ConversationModel(repository: repository)
        composerModel = ComposerModel(database: database)
        notifications.openConversation = { [weak self] id in
            self?.select(id)
        }
        notifications.sendReply = { [weak self] id, text in
            self?.quickReply(to: id, text: text)
        }
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
                async let marks = database.readMarks()
                async let loadedFolders = database.folders()
                async let loadedMembers = database.folderMembers()
                let (loadedPage, loadedPins, loadedMarks, folderList, memberMap) =
                    try await (page, pins, marks, loadedFolders, loadedMembers)
                pinnedIDs = loadedPins
                clearedUnreadAt = loadedMarks
                folders = folderList
                folderMembers = memberMap
                // Drop a stale folder scope whose folder was deleted while away.
                if let selected = selectedFolderID, !folderList.contains(where: { $0.id == selected }) {
                    selectedFolderID = nil
                }
                conversations = sort(loadedPage.conversations)
                state = conversations.isEmpty ? .empty : .loaded
                updateDockBadge()
                startEventStream()
                if providerMode == .messages {
                    notifications.prepare()
                }
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

    /// Sidebar list after the unread-only filter. The selected conversation
    /// stays visible so toggling the filter never yanks the open thread.
    var visibleConversations: [Conversation] {
        // Folder scope narrows the pool first; the filter axis then applies to
        // that slice, so the two compose (e.g. "unread within Work"). The open
        // thread always stays visible so switching scopes never yanks it.
        let scoped: [Conversation]
        if let folderID = selectedFolderID {
            // Scope to members even when the folder is empty — an empty folder
            // shows nothing, not everything. The open thread stays visible.
            let members = folderMembers[folderID] ?? []
            scoped = conversations.filter { members.contains($0.id) || $0.id == selectedConversationID }
        } else {
            scoped = conversations
        }
        switch filter {
        case .all:
            return scoped
        case .unread:
            return scoped.filter {
                hasVisibleUnread($0) || $0.id == selectedConversationID
            }
        case .needsReply:
            let now = Date.now
            return scoped.filter {
                NeedsReply.needsReply($0, now: now) || $0.id == selectedConversationID
            }
        }
    }

    /// The currently-scoped folder, if any. Drives the sidebar's selected state
    /// and empty-state copy.
    var selectedFolder: Folder? {
        guard let selectedFolderID else { return nil }
        return folders.first { $0.id == selectedFolderID }
    }

    /// Pinned conversations in sidebar order (they sort first).
    var pinnedConversations: [Conversation] {
        conversations.filter { pinnedIDs.contains($0.id) }
    }

    /// Total unread across every thread, honoring the local read-mark overlay.
    /// Drives both the Dock badge and the menu-bar status item's count.
    var unreadTotal: Int {
        conversations.filter(hasVisibleUnread).compactMap(\.unreadCount).reduce(0, +)
    }

    /// Most-recently-active threads for the menu-bar mini-inbox, newest first.
    /// Unlike the sidebar this ignores pin priority — here "recent" means recent.
    func recentConversations(limit: Int) -> [Conversation] {
        Array(conversations.sorted { $0.lastActivity > $1.lastActivity }.prefix(limit))
    }

    func selectPinned(at index: Int) {
        let pinned = pinnedConversations
        guard pinned.indices.contains(index) else { return }
        select(pinned[index].id)
    }

    func toggleSelectedPin() {
        guard let id = selectedConversationID else { return }
        togglePin(id)
    }

    func hasVisibleUnread(_ conversation: Conversation) -> Bool {
        guard let count = conversation.unreadCount, count > 0 else { return false }
        if let cleared = clearedUnreadAt[conversation.id], cleared >= conversation.lastActivity {
            return false
        }
        return true
    }

    func select(_ id: ConversationID?, focus: MessageID? = nil) {
        if selectedConversationID != id { selectedConversationID = id }
        if let id {
            markCleared(id)
            updateDockBadge()
        }
        guard conversationModel.conversation?.id != id else {
            if let focus { conversationModel.reveal(focus) }
            return
        }
        guard let conversation = conversations.first(where: { $0.id == id }) else {
            conversationModel.clear()
            composerModel.select(nil, capabilities: capabilities, health: health, sendAction: nil)
            return
        }
        conversationModel.select(conversation, reveal: focus)
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
            if message.conversationID == selectedConversationID {
                markCleared(message.conversationID)
            }
            maybeNotify(message)
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
        case .databaseChanged:
            // A write with no new row — in-place edit, tapback, or receipt.
            // Refresh the open thread so those changes show without a poll.
            conversationModel.refreshOpenThread()
        }
    }

    private func maybeNotify(_ message: Message) {
        guard providerMode == .messages, !message.isOutgoing else { return }
        let isViewing = message.conversationID == selectedConversationID && NSApp.isActive
        guard !isViewing else { return }
        let name = conversations.first(where: { $0.id == message.conversationID })?.displayName
            ?? message.sender?.displayName
            ?? message.sender?.handle
            ?? "New message"
        notifications.post(message: message, conversationName: name)
    }

    // MARK: - Compose

    var canCompose: Bool {
        CapabilityGate.canSend(capabilities: capabilities, health: health)
    }

    func contactSuggestions(matching term: String) async -> [ContactSuggestion] {
        await repository.contactSuggestions(matching: term)
    }

    /// Composing to a handle we already have a 1:1 thread with should open
    /// that thread instead of blind-sending.
    func existingDirectConversation(handle: String) -> Conversation? {
        let normalized = ContactsNameResolver.normalize(handle)
        guard !normalized.isEmpty else { return nil }
        return conversations.first { conversation in
            conversation.kind == .direct && conversation.participants.contains {
                ContactsNameResolver.normalize($0.handle) == normalized
            }
        }
    }

    /// Sends an inline notification reply to an existing thread. Fire-and-forget
    /// from the notification delegate; the poller reflects the sent message.
    func quickReply(to id: ConversationID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canCompose else { return }
        let repository = repository
        Task {
            do {
                _ = try await repository.send(SendRequest(
                    operationID: UUID(),
                    conversationID: id,
                    text: trimmed,
                    attachments: []
                ))
            } catch {
                AppLog.repository.error("Quick reply failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func sendDirect(handle: String, text: String) async -> SendOutcome {
        let request = DirectSendRequest(operationID: UUID(), handle: handle, text: text)
        let repository = repository
        let outcome: SendOutcome
        do {
            outcome = try await repository.sendDirect(request)
        } catch {
            AppLog.repository.error("Direct send threw error=\(String(describing: type(of: error)), privacy: .public)")
            return .rejected(operationID: request.operationID, reason: .providerUnavailable)
        }
        if case .accepted = outcome {
            selectConversationWhenVisible(handle: handle)
        }
        return outcome
    }

    /// The poller surfaces the new thread within a couple of ticks; select it
    /// once it lands so the composer continues where the sheet left off.
    private func selectConversationWhenVisible(handle: String) {
        Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let conversation = self.existingDirectConversation(handle: handle) {
                    self.select(conversation.id)
                    return
                }
            }
        }
    }

    private func markCleared(_ id: ConversationID) {
        let now = Date.now
        clearedUnreadAt[id] = now
        Task {
            do {
                try await database.setReadMark(now, conversationID: id)
            } catch {
                AppLog.database.error("Read-mark persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
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

    // MARK: - Folders

    /// Folder IDs a conversation currently belongs to — feeds the context-menu
    /// checkmarks.
    func folders(containing id: ConversationID) -> Set<String> {
        var result: Set<String> = []
        for (folderID, members) in folderMembers where members.contains(id) {
            result.insert(folderID)
        }
        return result
    }

    /// How many conversations are filed under a folder — the sidebar count badge.
    func memberCount(of folderID: String) -> Int {
        folderMembers[folderID]?.count ?? 0
    }

    func selectFolder(_ id: String?) {
        selectedFolderID = id
    }

    /// Creates a folder, optionally filing `seedConversation` into it (from the
    /// "New Folder…" affordance in a conversation's context menu). Optimistic:
    /// mirror the new folder locally, then persist.
    func createFolder(name: String, colorName: String, seedConversation: ConversationID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let nextOrder = (folders.map(\.sortOrder).max() ?? 0) + 1
        let folder = Folder(id: UUID().uuidString, name: trimmed, colorName: colorName, sortOrder: nextOrder)
        folders.append(folder)
        if let seedConversation {
            folderMembers[folder.id, default: []].insert(seedConversation)
        }
        Task {
            do {
                // Persist with the same id we optimistically inserted so the
                // local and stored rows stay in lockstep.
                try await database.insertFolder(folder, createdAt: Date())
                if let seedConversation {
                    try await database.setFolderMembership(folderID: folder.id, conversationID: seedConversation, member: true)
                }
            } catch {
                AppLog.database.error("Folder create failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func updateFolder(_ id: String, name: String, colorName: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        folders[index].colorName = colorName
        Task {
            do {
                try await database.updateFolder(id: id, name: trimmed, colorName: colorName)
            } catch {
                AppLog.database.error("Folder update failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func deleteFolder(_ id: String) {
        folders.removeAll { $0.id == id }
        folderMembers.removeValue(forKey: id)
        if selectedFolderID == id { selectedFolderID = nil }
        Task {
            do {
                try await database.deleteFolder(id: id)
            } catch {
                AppLog.database.error("Folder delete failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func toggleMembership(_ conversationID: ConversationID, inFolder folderID: String) {
        let isMember = folderMembers[folderID]?.contains(conversationID) ?? false
        if isMember {
            folderMembers[folderID]?.remove(conversationID)
        } else {
            folderMembers[folderID, default: []].insert(conversationID)
        }
        Task {
            do {
                try await database.setFolderMembership(folderID: folderID, conversationID: conversationID, member: !isMember)
            } catch {
                AppLog.database.error("Folder membership failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func search(text: String) async {
        let query = MessageSearchQuery(raw: text, limit: 100)
        guard query.hasCriteria else {
            searchResults = []
            return
        }
        do {
            searchResults = try await repository.search(query).messages
        } catch {
            searchResults = []
            AppLog.ui.error("Search failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func updateDockBadge() {
        let unread = unreadTotal
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

