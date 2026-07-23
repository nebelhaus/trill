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
    /// Only threads that hold an unsent draft. The sidebar hides this filter's
    /// affordances entirely when no drafts exist.
    case drafts
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
    /// The active tab. Always an element of `openTabs`, or `nil` when nothing is
    /// open. Persisted so the active thread survives a relaunch.
    @Published var selectedConversationID: ConversationID? {
        didSet { persistActiveTab() }
    }
    @Published private(set) var health: ProviderHealth = .fixture
    @Published private(set) var capabilities = ProviderCapabilities()
    @Published private(set) var pinnedIDs: Set<ConversationID> = []
    /// VIP conversations (local overlay): always sorted above everything, given
    /// their own sidebar section, and always allowed to notify. A superset of
    /// pinning — a VIP is implicitly pinned even without a `pinnedIDs` entry.
    @Published private(set) var vipIDs: Set<ConversationID> = []
    /// Bookmarked message IDs (local overlay). Drives the star toggle + glyph in
    /// the timeline and the Universal Library's Saved tab. No chat.db write.
    @Published private(set) var savedMessageIDs: Set<MessageID> = []
    /// Conversations holding an unsent draft. Seeded from the database on load,
    /// then kept live by the composer via `onDraftChanged`. Drives the Drafts
    /// filter and the visibility of its sidebar affordances.
    @Published private(set) var draftIDs: Set<ConversationID> = []
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
    /// Conversations the user has archived — hidden from every normal scope and
    /// reachable only through the sidebar's Archived scope. Overlay-only.
    @Published private(set) var archivedIDs: Set<ConversationID> = []
    /// Conversations whose notifications are suppressed locally. Checked in
    /// `maybeNotify`; they otherwise stay in the list (with a muted glyph).
    @Published private(set) var mutedIDs: Set<ConversationID> = []
    /// Snoozed threads → the time they resurface. Currently-snoozed conversations
    /// (`wake > now`) are hidden from the list; a scheduler prunes each entry when
    /// its wake time arrives, which republishes this map and brings the thread back.
    @Published private(set) var snoozedUntil: [ConversationID: Date] = [:]
    /// When set, the sidebar shows the Archived scope instead of the normal list.
    /// Mutually exclusive with a folder scope (picking either clears the other).
    @Published var showingArchived = false
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
    /// The Universal Library (⌘⇧L) overlay — all-conversations media browser.
    @Published var isLibraryPresented = false
    /// The global writing-style profile sheet — scans your own messages across
    /// every conversation into a document you can hand to an AI model.
    @Published var isStyleProfilePresented = false
    /// The keyboard cheat-sheet (⌘/) overlay — every keybinding at a glance.
    @Published var isShortcutsPresented = false
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

    var showsDraftsOnly: Bool {
        get { filter == .drafts }
        set { filter = newValue ? .drafts : .all }
    }

    /// Whether any conversation currently holds a draft. The sidebar keys the
    /// Drafts filter's visibility off this, so the affordance simply isn't there
    /// when there's nothing to show.
    var hasDrafts: Bool { !draftIDs.isEmpty }

    /// Services hidden from the sidebar. Unlike `filter`, this is a *composable*
    /// axis (you can hide SMS while also scoping to a folder or unread), so it's
    /// a set rather than a mutually-exclusive case. Empty = show everything. Only
    /// `MessageServiceKind.togglable` services are ever placed here; `.unknown`
    /// is never hidden. Persisted across launches.
    @Published var hiddenServices: Set<MessageServiceKind> = InboxModel.loadHiddenServices() {
        didSet {
            UserDefaults.standard.set(
                hiddenServices.map(\.rawValue).sorted().joined(separator: ","),
                forKey: InboxModel.hiddenServicesKey
            )
        }
    }

    /// Whether a service is currently shown (drives the menu's checkmarks).
    func showsService(_ service: MessageServiceKind) -> Bool {
        !hiddenServices.contains(service)
    }

    /// Flip one service in or out of the sidebar.
    func toggleService(_ service: MessageServiceKind) {
        if hiddenServices.contains(service) {
            hiddenServices.remove(service)
        } else {
            hiddenServices.insert(service)
        }
    }

    /// Clear the service filter entirely — the menu's explicit "off" switch.
    func showAllServices() {
        hiddenServices.removeAll()
    }

    @Published private(set) var providerMode: ProviderMode = .fixture
    @Published private(set) var errorSummary: String?

    /// Open conversation tabs, in strip order. The active tab is
    /// `selectedConversationID`; the strip hides itself below two entries.
    /// Persisted (as `ConversationID` keys) so tabs restore between launches.
    @Published private(set) var openTabs: [ConversationID] = [] {
        didSet { persistOpenTabs() }
    }
    /// One warm `ConversationModel` per open tab, so switching tabs is instant and
    /// background tabs keep receiving live messages. Invariant: its key set equals
    /// `Set(openTabs)`.
    private var tabModels: [ConversationID: ConversationModel] = [:]
    /// Shown when no tab is active (nothing selected), keeping the computed
    /// `conversationModel` non-optional so existing call sites are unchanged.
    private let placeholderConversationModel: ConversationModel
    /// The active tab's warm timeline, or the placeholder when nothing's selected.
    /// Computed so it swaps instances on a tab switch — SwiftUI re-binds the
    /// `ConversationView`'s `@ObservedObject` to the new tab automatically.
    var conversationModel: ConversationModel {
        selectedConversationID.flatMap { tabModels[$0] } ?? placeholderConversationModel
    }
    /// Which thread the shared composer is pointed at, so the idempotent re-entry
    /// through `selectedConversationID`'s onChange doesn't re-point (and re-restore
    /// the draft on) an already-active thread.
    private var composerConversationID: ConversationID?
    /// Cap on warm tabs. Opens are explicit, so this only bites pathological cases;
    /// the oldest non-active tab is evicted past it.
    private static let maxTabs = 12
    let composerModel: ComposerModel
    /// Shared, cached Open Graph fetcher for the Universal Library's Links tab.
    let linkPreviewLoader: LinkPreviewLoader

    private let database: AppDatabase
    private let notifications = NotificationCoordinator()
    private var repository: MessagesRepository
    private var loadTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    /// Browser-style navigation history over the *selected conversation*. `back`
    /// holds previously-viewed threads (most recent last); `forward` holds the
    /// ones a ⌘[ back-step stepped out of, cleared the moment a fresh selection
    /// forks the trail. Published so the ⌘[ / ⌘] menu items can enable/disable.
    @Published private(set) var backStack: [ConversationID] = []
    @Published private(set) var forwardStack: [ConversationID] = []
    /// Set only while `goBack`/`goForward` drive the selection, so `select`'s
    /// history recorder knows this hop is a replay, not a new fork.
    private var isNavigatingHistory = false
    /// Cap so a marathon session can't grow the trail without bound.
    private static let historyLimit = 50
    /// Fires when the next-to-wake snoozed thread is due, so it resurfaces
    /// without a poll. Rescheduled whenever the snooze set changes.
    private var snoozeWakeTask: Task<Void, Never>?
    /// Re-probes provider health when the app returns to the foreground, so a
    /// permission granted in System Settings while away (Full Disk Access,
    /// Automation, Contacts) reflects in the UI without a relaunch.
    private var healthRefreshTask: Task<Void, Never>?
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can remove it: the token
    /// is a non-`Sendable` `NSObjectProtocol`, but it's only ever assigned on the
    /// main actor and `NotificationCenter.removeObserver` is thread-safe.
    nonisolated(unsafe) private var foregroundObserver: NSObjectProtocol?
    private static let providerModeKey = "providerMode"
    private static let filterKey = "inboxFilter"
    private static let selectedFolderKey = "selectedFolderID"
    private static let hiddenServicesKey = "hiddenServices"
    private static let openTabsKey = "openTabs"
    private static let activeTabKey = "activeTab"

    private static func loadPersistedFilter() -> InboxFilter {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: filterKey), let stored = InboxFilter(rawValue: raw) {
            return stored
        }
        // One-time migration from the pre-triage unread-only bool.
        return defaults.bool(forKey: "showsUnreadOnly") ? .unread : .all
    }

    private static func loadHiddenServices() -> Set<MessageServiceKind> {
        guard let raw = UserDefaults.standard.string(forKey: hiddenServicesKey), !raw.isEmpty else {
            return []
        }
        return Set(raw.split(separator: ",").compactMap { MessageServiceKind(rawValue: String($0)) })
    }

    init(database: AppDatabase, snippets: SnippetStore) {
        self.database = database
        linkPreviewLoader = LinkPreviewLoader(database: database)
        let mode = UserDefaults.standard.string(forKey: Self.providerModeKey)
            .flatMap(ProviderMode.init(rawValue:)) ?? .messages
        providerMode = mode
        let repository = MessagesRepository(provider: Self.makeProvider(mode), database: database)
        self.repository = repository
        placeholderConversationModel = ConversationModel(repository: repository)
        composerModel = ComposerModel(database: database, snippets: snippets)
        composerModel.onDraftChanged = { [weak self] id, hasContent in
            self?.updateDraftMembership(id, hasContent: hasContent)
        }
        composerModel.onSent = { [weak self] id in
            // Take the reader to the bottom to see the message they just sent —
            // it arrives asynchronously from chat.db, so the tab's timeline
            // follows its tail until the new row lands.
            self?.tabModels[id]?.scrollToBottom()
        }
        notifications.openConversation = { [weak self] id in
            self?.select(id)
        }
        notifications.sendReply = { [weak self] id, text in
            self?.quickReply(to: id, text: text)
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshHealthOnForeground() }
        }
    }

    deinit {
        loadTask?.cancel()
        eventTask?.cancel()
        snoozeWakeTask?.cancel()
        healthRefreshTask?.cancel()
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    /// Re-read provider health on foreground. Only the live provider's runtime
    /// permission state can change while away (Full Disk Access, Automation,
    /// Contacts), so this is a no-op in fixture mode or before the first load.
    /// It updates only `health` — never `state` — so it can't disturb an active
    /// error/empty screen; it exists so health-gated affordances reflect a grant
    /// the moment it lands, not on next launch.
    private func refreshHealthOnForeground() {
        guard providerMode == .messages else { return }
        // While parked on a permission-recovery screen, the user has just been in
        // System Settings — re-drive the full load so a live-updatable grant
        // (Automation, Contacts) clears the screen without a manual Recheck. FDA
        // still needs a relaunch (see `relaunch()`), but re-loading is harmless.
        switch state {
        case .permissionMissing, .providerUnavailable, .unsupportedSchema:
            load()
            return
        case .loaded:
            break
        default:
            return
        }
        healthRefreshTask?.cancel()
        let repository = repository
        healthRefreshTask = Task { [weak self] in
            let refreshed = await repository.health()
            guard !Task.isCancelled else { return }
            self?.health = refreshed
        }
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
                async let vips = database.vipConversationIDs()
                async let marks = database.readMarks()
                async let loadedFolders = database.folders()
                async let loadedMembers = database.folderMembers()
                async let saved = database.savedMessageIDs()
                async let loadedArchived = database.archivedConversationIDs()
                async let loadedMuted = database.mutedConversationIDs()
                async let loadedSnoozed = database.snoozedConversations()
                async let loadedDrafts = database.draftConversationIDs()
                let (loadedPage, loadedPins, loadedVIPs, loadedMarks, folderList, memberMap) =
                    try await (page, pins, vips, marks, loadedFolders, loadedMembers)
                let loadedSaved = try await saved
                let (archived, muted, snoozed) = try await (loadedArchived, loadedMuted, loadedSnoozed)
                let drafts = try await loadedDrafts
                pinnedIDs = loadedPins
                vipIDs = loadedVIPs
                savedMessageIDs = loadedSaved
                draftIDs = drafts
                // A draft can vanish while away (e.g. sent from Messages.app);
                // don't strand the user on a Drafts view that's now empty.
                if drafts.isEmpty, filter == .drafts { filter = .all }
                clearedUnreadAt = loadedMarks
                folders = folderList
                folderMembers = memberMap
                archivedIDs = archived
                mutedIDs = muted
                snoozedUntil = snoozed
                // Prune snoozes that lapsed while away, then arm the wake timer.
                pruneAndScheduleSnoozes()
                if archived.isEmpty { showingArchived = false }
                // Drop a stale folder scope whose folder was deleted while away.
                if let selected = selectedFolderID, !folderList.contains(where: { $0.id == selected }) {
                    selectedFolderID = nil
                }
                conversations = sort(loadedPage.conversations)
                restoreTabs()
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
        // The trail and open tabs belong to the old provider's thread list; a
        // switch retires them.
        backStack.removeAll()
        forwardStack.removeAll()
        openTabs.removeAll()
        tabModels.removeAll()
        composerConversationID = nil
        eventTask?.cancel()
        composerModel.select(nil, capabilities: ProviderCapabilities(), health: .fixture, sendAction: nil)

        repository = MessagesRepository(provider: Self.makeProvider(mode), database: database)
        placeholderConversationModel.updateRepository(repository)
        load()
    }

    /// Sidebar list after the unread-only filter. The selected conversation
    /// stays visible so toggling the filter never yanks the open thread.
    var visibleConversations: [Conversation] {
        // The Archived scope is its own world: it shows exactly the archived
        // threads (plus the open one) and ignores the folder/filter axes.
        if showingArchived {
            return conversations.filter { archivedIDs.contains($0.id) || $0.id == selectedConversationID }
        }
        // Archived and currently-snoozed threads drop out of every normal scope.
        // The open thread always survives so acting on it never yanks it away.
        let now = Date.now
        let active = conversations.filter { conversation in
            conversation.id == selectedConversationID
                || (!archivedIDs.contains(conversation.id) && !isSnoozed(conversation.id, now: now))
        }
        // Folder scope narrows the pool next; the filter axis then applies to
        // that slice, so the two compose (e.g. "unread within Work"). The open
        // thread always stays visible so switching scopes never yanks it.
        let scoped: [Conversation]
        if let folderID = selectedFolderID {
            // Scope to members even when the folder is empty — an empty folder
            // shows nothing, not everything. The open thread stays visible.
            let members = folderMembers[folderID] ?? []
            scoped = active.filter { members.contains($0.id) || $0.id == selectedConversationID }
        } else {
            scoped = active
        }
        // Service axis narrows next, composing with folder scope and the filter
        // below (e.g. "unread iMessage within Work"). Hidden services drop out;
        // the open thread always stays visible so hiding its service never yanks
        // it. Empty set is the common case, so skip the pass entirely then.
        let serviced: [Conversation]
        if hiddenServices.isEmpty {
            serviced = scoped
        } else {
            serviced = scoped.filter {
                !hiddenServices.contains($0.service) || $0.id == selectedConversationID
            }
        }
        switch filter {
        case .all:
            return serviced
        case .unread:
            return serviced.filter {
                hasVisibleUnread($0) || $0.id == selectedConversationID
            }
        case .needsReply:
            return serviced.filter {
                NeedsReply.needsReply($0, now: now) || $0.id == selectedConversationID
            }
        case .drafts:
            return serviced.filter {
                draftIDs.contains($0.id) || $0.id == selectedConversationID
            }
        }
    }

    /// Keep the Drafts overlay in lockstep with the composer. Idempotent: a
    /// conversation is in the set exactly when it has text, so we can insert or
    /// remove without knowing the prior state. Removing the last draft while the
    /// Drafts filter is active falls back to All so the view can't get stuck
    /// empty with its toggle gone.
    private func updateDraftMembership(_ id: ConversationID, hasContent: Bool) {
        if hasContent {
            draftIDs.insert(id)
        } else {
            draftIDs.remove(id)
            if draftIDs.isEmpty, filter == .drafts { filter = .all }
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

    func isVIP(_ id: ConversationID) -> Bool { vipIDs.contains(id) }

    /// Whether the sidebar should break out a dedicated VIP section. Only in the
    /// unscoped "All Messages" view — a folder scope is already its own slice —
    /// and only when at least one VIP survives the active filter.
    var showsVIPSection: Bool {
        selectedFolderID == nil && !visibleVIPConversations.isEmpty
    }

    /// VIPs within the current visible slice, in sidebar (VIP-first) order.
    var visibleVIPConversations: [Conversation] {
        visibleConversations.filter { vipIDs.contains($0.id) }
    }

    /// The rest of the visible slice. When `showsVIPSection` is false this is the
    /// whole list, so the sidebar renders this unconditionally and only prepends
    /// the VIP section when the flag is set.
    var visibleNonVIPConversations: [Conversation] {
        guard showsVIPSection else { return visibleConversations }
        return visibleConversations.filter { !vipIDs.contains($0.id) }
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

    /// Navigate the *active* tab to `id` in place (the browser model: clicking a
    /// sidebar row reuses the current tab). `nil` deselects without touching the
    /// open tab set, so the compact back button leaves tabs intact.
    func select(_ id: ConversationID?, focus: MessageID? = nil) {
        recordHistory(navigatingTo: id)
        guard let id else {
            if selectedConversationID != nil { selectedConversationID = nil }
            pointComposer(at: nil)
            return
        }
        ensureOpen(id, mode: .replaceActive)
        activate(id, focus: focus)
    }

    /// Open `id` in a new tab (⌘T / double-click / ⌘-click a sidebar row). If it's
    /// already open this just activates that tab.
    func openInNewTab(_ id: ConversationID?) {
        guard let id, conversations.contains(where: { $0.id == id }) else { return }
        guard !openTabs.contains(id) else { activateTab(id); return }
        recordHistory(navigatingTo: id)
        ensureOpen(id, mode: .newTab)
        activate(id, focus: nil)
    }

    /// Switch the active tab to an already-open one (strip click, ⌘⇧[ / ⌘⇧]).
    func activateTab(_ id: ConversationID) {
        guard openTabs.contains(id), selectedConversationID != id else { return }
        recordHistory(navigatingTo: id)
        activate(id, focus: nil)
    }

    /// Close a tab. If it was active, land on the neighbor that slides into its
    /// place (else the previous one, else nothing).
    func closeTab(_ id: ConversationID) {
        guard let index = openTabs.firstIndex(of: id) else { return }
        openTabs.remove(at: index)
        tabModels.removeValue(forKey: id)
        guard selectedConversationID == id else { return }
        if openTabs.indices.contains(index) {
            activate(openTabs[index], focus: nil)
        } else if let last = openTabs.last {
            activate(last, focus: nil)
        } else {
            select(nil)
        }
    }

    func nextTab() { cycleTab(by: 1) }
    func previousTab() { cycleTab(by: -1) }

    private func cycleTab(by delta: Int) {
        guard openTabs.count > 1,
              let active = selectedConversationID,
              let index = openTabs.firstIndex(of: active) else { return }
        let next = openTabs[(index + delta + openTabs.count) % openTabs.count]
        activateTab(next)
    }

    /// Reorder the strip: move `dragged` to `target`'s slot. Called repeatedly as
    /// a drag hovers over each chip, so it only needs to handle a single hop.
    /// Touches order only — the warm models are keyed by id, so they ride along —
    /// and the active tab is unaffected.
    func moveTab(_ dragged: ConversationID, to target: ConversationID) {
        guard dragged != target,
              let from = openTabs.firstIndex(of: dragged),
              let to = openTabs.firstIndex(of: target) else { return }
        var tabs = openTabs
        tabs.remove(at: from)
        tabs.insert(dragged, at: to)
        openTabs = tabs
    }

    /// Whether `id` is the active tab — drives the strip's highlight.
    func isActiveTab(_ id: ConversationID) -> Bool { selectedConversationID == id }

    private enum OpenMode { case replaceActive, newTab }

    /// Ensure `id` is an open tab with a warm, loaded `ConversationModel`, keeping
    /// `Set(openTabs) == Set(tabModels.keys)`. `.replaceActive` swaps the active
    /// tab's slot in place; `.newTab` appends (evicting the oldest past the cap).
    private func ensureOpen(_ id: ConversationID, mode: OpenMode) {
        // Tabs only exist for real, loaded threads. Selecting an id that isn't in
        // the list (e.g. a programmatic jump before load) still sets the active
        // selection in `activate` — it just doesn't spawn a tab or warm model.
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        if !openTabs.contains(id) {
            switch mode {
            case .replaceActive:
                if let active = selectedConversationID, let index = openTabs.firstIndex(of: active) {
                    openTabs[index] = id
                    tabModels.removeValue(forKey: active)
                } else {
                    openTabs.append(id)
                }
            case .newTab:
                openTabs.append(id)
                enforceTabCap(keeping: id)
            }
        }
        if tabModels[id] == nil {
            let model = ConversationModel(repository: repository)
            model.select(conversation)
            tabModels[id] = model
        }
    }

    /// Make `id` the active tab: point the selection, composer, and (if asked) the
    /// reveal at it. The warm model is already loaded by `ensureOpen`, so a switch
    /// to an existing tab does no reload.
    private func activate(_ id: ConversationID, focus: MessageID?) {
        if selectedConversationID != id { selectedConversationID = id }
        markCleared(id)
        updateDockBadge()
        if let focus { tabModels[id]?.reveal(focus) }
        pointComposer(at: id)
    }

    /// Re-point the shared composer at `id`, guarded so the onChange re-entry
    /// (row tap → `select` sets `selectedConversationID` → onChange → `select`)
    /// doesn't re-restore an already-active draft.
    private func pointComposer(at id: ConversationID?) {
        guard composerConversationID != id else { return }
        composerConversationID = id
        guard let id, let conversation = conversations.first(where: { $0.id == id }) else {
            composerModel.select(nil, capabilities: capabilities, health: health, sendAction: nil)
            return
        }
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

    private func enforceTabCap(keeping id: ConversationID) {
        while openTabs.count > Self.maxTabs,
              let victim = openTabs.first(where: { $0 != id && $0 != selectedConversationID }) {
            openTabs.removeAll { $0 == victim }
            tabModels.removeValue(forKey: victim)
        }
    }

    // MARK: - Tab persistence

    private func persistOpenTabs() {
        UserDefaults.standard.set(openTabs.map(\.persistenceKey), forKey: Self.openTabsKey)
    }

    private func persistActiveTab() {
        UserDefaults.standard.set(selectedConversationID?.persistenceKey, forKey: Self.activeTabKey)
    }

    /// Rebuild the open tabs from the persisted keys, dropping any thread that's no
    /// longer in the loaded list, then activate the persisted (or first) tab.
    private func restoreTabs() {
        guard openTabs.isEmpty else { return }
        let keys = UserDefaults.standard.stringArray(forKey: Self.openTabsKey) ?? []
        let ids = keys
            .compactMap(ConversationID.init(persistenceKey:))
            .filter { id in conversations.contains { $0.id == id } }
        guard !ids.isEmpty else { return }
        for id in ids { ensureOpen(id, mode: .newTab) }
        let active = UserDefaults.standard.string(forKey: Self.activeTabKey)
            .flatMap(ConversationID.init(persistenceKey:))
        activate(active.flatMap { ids.contains($0) ? $0 : nil } ?? ids[0], focus: nil)
    }

    // MARK: - Navigation history

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// Push the thread we're leaving onto the back trail whenever a *fresh*
    /// selection moves to a different conversation, and fork the forward trail.
    /// Replays driven by `goBack`/`goForward` skip this so they don't rewrite the
    /// very history they're walking.
    private func recordHistory(navigatingTo id: ConversationID?) {
        guard !isNavigatingHistory else { return }
        guard let id, let current = selectedConversationID, current != id else { return }
        backStack.append(current)
        if backStack.count > Self.historyLimit { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    /// ⌘[ — step back to the previously-viewed conversation.
    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selectedConversationID { forwardStack.append(current) }
        navigateHistory(to: previous)
    }

    /// ⌘] — step forward again after one or more ⌘[ back-steps.
    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selectedConversationID { backStack.append(current) }
        navigateHistory(to: next)
    }

    private func navigateHistory(to id: ConversationID) {
        isNavigatingHistory = true
        select(id)
        isNavigatingHistory = false
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
            // Fan out to whichever open tab owns the thread, so a background tab's
            // warm timeline stays current — not just the active one.
            tabModels[message.conversationID]?.appendLive(message)
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
            // Refresh every open tab so those changes show without a poll; each
            // model guards on its own conversation.
            for model in tabModels.values { model.refreshOpenThread() }
        }
    }

    private func maybeNotify(_ message: Message) {
        guard providerMode == .messages, !message.isOutgoing else { return }
        // Mute is the strongest gate: an explicitly muted thread never alerts,
        // even a VIP. (VIP is "always-notify" only relative to the default — the
        // user muting it is a deliberate override that wins.)
        guard !mutedIDs.contains(message.conversationID) else { return }
        let isViewing = message.conversationID == selectedConversationID && NSApp.isActive
        guard !isViewing else { return }
        let name = conversations.first(where: { $0.id == message.conversationID })?.displayName
            ?? message.sender?.displayName
            ?? message.sender?.handle
            ?? "New message"
        // VIP (unmuted) threads get a distinct ⭐ banner.
        notifications.post(message: message, conversationName: name, isVIP: vipIDs.contains(message.conversationID))
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

    func toggleVIP(_ id: ConversationID) {
        let shouldVIP = !vipIDs.contains(id)
        if shouldVIP { vipIDs.insert(id) } else { vipIDs.remove(id) }
        // VIP outranks pinning in the sort, so re-sort to float it to the top
        // (or drop it back among the pins/rest when un-VIP'd).
        conversations = sort(conversations)
        Task {
            do {
                try await database.setVIP(shouldVIP, conversationID: id)
            } catch {
                AppLog.database.error("VIP persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func isSaved(_ id: MessageID) -> Bool { savedMessageIDs.contains(id) }

    /// Bookmarks or un-bookmarks a message. Optimistic in-memory update (so the
    /// star and the Saved tab react immediately) with a background overlay write,
    /// mirroring `togglePin`/`toggleVIP`.
    func toggleSaved(_ id: MessageID) {
        let shouldSave = !savedMessageIDs.contains(id)
        if shouldSave { savedMessageIDs.insert(id) } else { savedMessageIDs.remove(id) }
        Task {
            do {
                try await database.setSaved(shouldSave, messageID: id)
            } catch {
                AppLog.database.error("Saved-message persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func toggleSelectedVIP() {
        guard let id = selectedConversationID else { return }
        toggleVIP(id)
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
        // Folder scope and the Archived scope are mutually exclusive views.
        showingArchived = false
    }

    /// Switch the sidebar into (or out of) the Archived scope. Entering it drops
    /// any folder scope so the two never overlap.
    func showArchived(_ show: Bool) {
        showingArchived = show
        if show { selectedFolderID = nil }
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

    // MARK: - Archive / Mute / Snooze

    func isArchived(_ id: ConversationID) -> Bool { archivedIDs.contains(id) }

    func isMuted(_ id: ConversationID) -> Bool { mutedIDs.contains(id) }

    /// A thread counts as snoozed only while its wake time is still in the future.
    func isSnoozed(_ id: ConversationID, now: Date = .now) -> Bool {
        guard let wake = snoozedUntil[id] else { return false }
        return wake > now
    }

    func setArchived(_ id: ConversationID, archived: Bool) {
        if archived { archivedIDs.insert(id) } else { archivedIDs.remove(id) }
        // Leaving the Archived scope empty would strand the user on a blank list.
        if archivedIDs.isEmpty { showingArchived = false }
        Task {
            do {
                try await database.setArchived(archived, conversationID: id)
            } catch {
                AppLog.database.error("Archive persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func toggleArchived(_ id: ConversationID) { setArchived(id, archived: !archivedIDs.contains(id)) }

    func setMuted(_ id: ConversationID, muted: Bool) {
        if muted { mutedIDs.insert(id) } else { mutedIDs.remove(id) }
        Task {
            do {
                try await database.setMuted(muted, conversationID: id)
            } catch {
                AppLog.database.error("Mute persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    func toggleMuted(_ id: ConversationID) { setMuted(id, muted: !mutedIDs.contains(id)) }

    /// Snooze a thread until `option`'s wake time, hiding it until then.
    func snooze(_ id: ConversationID, option: SnoozeOption) {
        let wake = option.wakeDate(from: .now)
        snoozedUntil[id] = wake
        persistSnooze(id, wake: wake)
        rescheduleSnoozeWake()
    }

    /// Cancel a snooze, returning the thread to the list immediately.
    func unsnooze(_ id: ConversationID) {
        snoozedUntil.removeValue(forKey: id)
        persistSnooze(id, wake: nil)
        rescheduleSnoozeWake()
    }

    private func persistSnooze(_ id: ConversationID, wake: Date?) {
        Task {
            do {
                try await database.setSnooze(until: wake, conversationID: id)
            } catch {
                AppLog.database.error("Snooze persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Drop any snoozes whose wake time has already arrived (persisting the
    /// removals) and arm a timer for the next one due. Called on load and after
    /// every snooze change so resurfacing is exact, not polled.
    private func pruneAndScheduleSnoozes() {
        let now = Date.now
        let expired = snoozedUntil.filter { $0.value <= now }
        for id in expired.keys {
            snoozedUntil.removeValue(forKey: id)
            persistSnooze(id, wake: nil)
        }
        rescheduleSnoozeWake()
    }

    private func rescheduleSnoozeWake() {
        snoozeWakeTask?.cancel()
        guard let next = snoozedUntil.values.min() else { return }
        let interval = max(next.timeIntervalSinceNow, 0)
        snoozeWakeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard let self, !Task.isCancelled else { return }
            self.pruneAndScheduleSnoozes()
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

    // MARK: - Universal Library

    /// Every image, link, or file across all conversations, for the ⌘⇧L browser.
    func loadLibrary(kind: LibraryKind, limit: Int = 300) async -> [LibraryItem] {
        (try? await repository.libraryItems(kind: kind, limit: limit)) ?? []
    }

    /// Display name of a loaded conversation, for library-item context. Nil when
    /// the thread isn't in the currently-loaded list.
    func conversationName(for id: ConversationID) -> String? {
        conversations.first(where: { $0.id == id })?.displayName
    }

    // MARK: - Writing-style profile

    /// My own text messages across every conversation, newest-first, for the
    /// global writing-style profile. Bounded so a huge history can't stall the
    /// sheet; a few thousand recent messages is ample to characterize a voice.
    /// Read-only; returns whatever it gathered on error rather than throwing.
    func loadMyMessages(limit: Int = 4_000) async -> [Message] {
        (try? await repository.myMessages(limit: limit)) ?? []
    }

    // MARK: - Bulk export

    /// Every conversation, paging past the sidebar's first-page cap — the source
    /// list for "export all conversations" and its pick-a-subset picker. Read-only
    /// (never touches chat.db beyond the provider's own reads). Newest first, to
    /// match the sidebar. Returns whatever it gathered on error rather than throwing.
    func allConversationsForExport() async -> [Conversation] {
        var gathered: [Conversation] = []
        var cursor: String?
        var pagesRemaining = 1_000
        repeat {
            guard let page = try? await repository.conversations(
                page: ConversationPageRequest(limit: 200, cursor: cursor)
            ) else { break }
            gathered.append(contentsOf: page.conversations)
            cursor = page.nextCursor
            pagesRemaining -= 1
        } while cursor != nil && pagesRemaining > 0
        return gathered.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Full history of one thread for the bulk exporter — a thin passthrough to
    /// the repository's one-shot read. Empty on failure so one unreadable thread
    /// can't sink the whole run.
    func exportMessages(in id: ConversationID) async -> [Message] {
        (try? await repository.exportMessages(in: id)) ?? []
    }

    /// Jump from a library item to its source message, closing the library.
    func openLibraryItem(_ item: LibraryItem) {
        isLibraryPresented = false
        select(item.conversationID, focus: item.messageID)
    }

    private func updateDockBadge() {
        let unread = unreadTotal
        NSApp.dockTile.badgeLabel = unread > 0 ? String(unread) : nil
    }

    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Quit and re-exec Trill. Full Disk Access is bound to the process at launch,
    /// so a running instance that started without it can't gain read access to
    /// `chat.db` until it relaunches — no amount of in-app rechecking helps. This
    /// collapses the manual quit-and-reopen into one click. `open -n` waits out our
    /// termination and starts a fresh instance that inherits the new grant.
    func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    private func sort(_ values: [Conversation]) -> [Conversation] {
        values.sorted { left, right in
            // VIP > pinned > recency. VIP implies always-pin, so it forms a tier
            // above the pin tier rather than reusing it.
            let leftVIP = vipIDs.contains(left.id)
            let rightVIP = vipIDs.contains(right.id)
            if leftVIP != rightVIP { return leftVIP }
            let leftPinned = pinnedIDs.contains(left.id)
            let rightPinned = pinnedIDs.contains(right.id)
            if leftPinned != rightPinned { return leftPinned }
            if left.lastActivity != right.lastActivity { return left.lastActivity > right.lastActivity }
            return left.id.id < right.id.id
        }
    }
}

