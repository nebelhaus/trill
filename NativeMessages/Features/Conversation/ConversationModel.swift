import Foundation

enum ConversationLoadState: Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed
}

@MainActor
final class ConversationModel: ObservableObject {
    @Published private(set) var conversation: Conversation?
    @Published private(set) var messages: [Message] = []
    @Published private(set) var nextBefore: String?
    @Published private(set) var state: ConversationLoadState = .idle
    @Published private(set) var isLoadingOlder = false
    /// Set when a loaded message should be scrolled into view (search result,
    /// reply-quote jump across pages). The view consumes it.
    @Published private(set) var revealTarget: MessageID?
    @Published private(set) var highlightedMessageID: MessageID?

    // MARK: Find in conversation (⌘F)

    /// Whether the in-thread find bar is showing.
    @Published var isFindPresented = false
    /// Live find query; bound to the find bar's text field. Recomputes matches
    /// on every keystroke.
    @Published var findQuery = "" {
        didSet { recomputeFindMatches() }
    }
    /// Matching message IDs in chronological (oldest → newest) order.
    @Published private(set) var findMatches: [MessageID] = []
    /// Same set, for O(1) per-row membership checks in the timeline.
    @Published private(set) var findMatchSet: Set<MessageID> = []
    /// Caret into `findMatches` — the match the view scrolls to and emphasizes.
    @Published private(set) var findCurrentIndex = 0

    /// The match currently under the find caret, if any.
    var currentFindMatchID: MessageID? {
        guard findMatches.indices.contains(findCurrentIndex) else { return nil }
        return findMatches[findCurrentIndex]
    }

    private var repository: MessagesRepository
    private var loadTask: Task<Void, Never>?
    private var isRefreshing = false

    init(repository: MessagesRepository) {
        self.repository = repository
    }

    deinit {
        loadTask?.cancel()
    }

    func updateRepository(_ repository: MessagesRepository) {
        loadTask?.cancel()
        self.repository = repository
        clear()
    }

    func clear() {
        loadTask?.cancel()
        conversation = nil
        messages = []
        nextBefore = nil
        state = .idle
        revealTarget = nil
        highlightedMessageID = nil
        resetFind()
    }

    func select(_ conversation: Conversation, reveal: MessageID? = nil) {
        loadTask?.cancel()
        self.conversation = conversation
        messages = []
        nextBefore = nil
        state = .loading
        revealTarget = nil
        highlightedMessageID = nil
        resetFind()
        let repository = repository
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await repository.messages(in: conversation.id, page: MessagePageRequest(limit: 36))
                guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
                messages = page.messages.sorted(by: Self.chronological)
                nextBefore = page.nextBefore
                state = messages.isEmpty ? .empty : .loaded
                if let reveal {
                    await revealMessage(reveal)
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.conversation?.id == conversation.id else { return }
                state = .failed
                AppLog.ui.error("Conversation load failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Edits, tapbacks, and delivery/read flags mutate existing chat.db rows,
    /// which the new-row event stream can't see. The WAL watcher signals every
    /// write via `.databaseChanged`; on each we re-fetch the newest page and
    /// merge changes in place. Coalesced with an in-flight guard so a burst of
    /// writes doesn't stack refreshes.
    func refreshOpenThread() {
        guard !isRefreshing, conversation != nil,
              state == .loaded || state == .empty else { return }
        isRefreshing = true
        Task { [weak self] in
            await self?.refreshRecent()
            self?.isRefreshing = false
        }
    }

    private func refreshRecent() async {
        guard let conversation, state == .loaded || state == .empty else { return }
        let repository = repository
        guard let page = try? await repository.messages(
            in: conversation.id,
            page: MessagePageRequest(limit: 36)
        ) else { return }
        guard self.conversation?.id == conversation.id else { return }

        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var changed = false
        for fresh in page.messages where byID[fresh.id] != fresh {
            byID[fresh.id] = fresh
            changed = true
        }
        guard changed else { return }
        messages = byID.values.sorted(by: Self.chronological)
        if state == .empty, !messages.isEmpty { state = .loaded }
        if nextBefore == nil { nextBefore = page.nextBefore }
        if isFindPresented { recomputeFindMatches() }
    }

    /// Merges a message arriving from the live event stream.
    func appendLive(_ message: Message) {
        guard conversation?.id == message.conversationID else { return }
        guard state == .loaded || state == .empty else { return }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages = (messages + [message]).sorted(by: Self.chronological)
        state = .loaded
        if isFindPresented { recomputeFindMatches() }
    }

    func reveal(_ id: MessageID) {
        Task { [weak self] in
            await self?.revealMessage(id)
        }
    }

    func consumeRevealTarget() {
        revealTarget = nil
    }

    // MARK: - Find in conversation

    /// Opens the find bar over the current thread. Scoped to the messages loaded
    /// in the timeline — paging earlier messages in re-runs the match.
    func beginFind() {
        guard conversation != nil else { return }
        isFindPresented = true
        recomputeFindMatches()
    }

    /// Closes the find bar and drops all match state.
    func endFind() {
        guard isFindPresented else { return }
        resetFind()
    }

    /// Advances the caret to the next (newer) match, wrapping at the end.
    func findNext() {
        guard !findMatches.isEmpty else { return }
        findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        revealCurrentFindMatch()
    }

    /// Moves the caret to the previous (older) match, wrapping at the start.
    func findPrevious() {
        guard !findMatches.isEmpty else { return }
        findCurrentIndex = (findCurrentIndex - 1 + findMatches.count) % findMatches.count
        revealCurrentFindMatch()
    }

    /// Case-insensitive substring match over message text, oldest → newest.
    nonisolated static func matchingMessageIDs(in messages: [Message], query: String) -> [MessageID] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return messages.filter { $0.text.lowercased().contains(needle) }.map(\.id)
    }

    private func recomputeFindMatches() {
        let previousCurrent = currentFindMatchID
        findMatches = Self.matchingMessageIDs(in: messages, query: findQuery)
        findMatchSet = Set(findMatches)
        guard !findMatches.isEmpty else {
            findCurrentIndex = 0
            return
        }
        // Keep the caret pinned to the same message across recomputes (typing a
        // longer query, paging older messages in). If it's gone — or this is a
        // fresh query — land on the newest match, nearest where the reader is,
        // and scroll to it.
        if let previousCurrent, let index = findMatches.firstIndex(of: previousCurrent) {
            findCurrentIndex = index
        } else {
            findCurrentIndex = findMatches.count - 1
            revealCurrentFindMatch()
        }
    }

    private func revealCurrentFindMatch() {
        guard let id = currentFindMatchID else { return }
        revealTarget = id
    }

    private func resetFind() {
        isFindPresented = false
        findMatches = []
        findMatchSet = []
        findCurrentIndex = 0
        // Assign through the stored property directly to avoid the didSet
        // recompute racing the cleared match state above.
        if !findQuery.isEmpty { findQuery = "" }
    }

    /// Pages backwards (bounded) until the target message is loaded, then
    /// asks the view to scroll to it and flashes a highlight.
    private func revealMessage(_ id: MessageID) async {
        var remainingPages = 10
        while !messages.contains(where: { $0.id == id }), nextBefore != nil, remainingPages > 0 {
            await loadOlder()
            remainingPages -= 1
        }
        guard messages.contains(where: { $0.id == id }) else { return }
        revealTarget = id
        highlightedMessageID = id
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_600))
            guard let self, self.highlightedMessageID == id else { return }
            self.highlightedMessageID = nil
        }
    }

    func loadMedia(limit: Int = 200) async -> [MediaItem] {
        guard let conversation else { return [] }
        let repository = repository
        return (try? await repository.media(in: conversation.id, limit: limit)) ?? []
    }

    /// Aggregates the whole thread's timestamps into the stats-panel figures.
    /// Nil when there's no open conversation; `.empty` when the thread has no
    /// messages. Reads the full history, so it runs on demand, not on every load.
    func loadStats() async -> ConversationStats? {
        guard let conversation else { return nil }
        let repository = repository
        guard let samples = try? await repository.statSamples(in: conversation.id) else { return nil }
        return ConversationStatsBuilder.build(from: samples, now: Date())
    }

    /// Pages the entire open thread for export, oldest → newest. Runs an
    /// independent paging loop off the shared timeline state so exporting a long
    /// history never disturbs what's scrolled into view. Bounded by `maxMessages`
    /// and a page-count guard so a runaway thread can't spin forever.
    func loadAllForExport(maxMessages: Int = 50_000) async -> [Message] {
        guard let conversation else { return [] }
        let repository = repository
        var collected: [MessageID: Message] = [:]
        var before: String?
        var pagesRemaining = 400
        repeat {
            guard let page = try? await repository.messages(
                in: conversation.id,
                page: MessagePageRequest(limit: 200, before: before)
            ) else { break }
            guard self.conversation?.id == conversation.id else { break }
            for message in page.messages { collected[message.id] = message }
            before = page.nextBefore
            pagesRemaining -= 1
        } while before != nil && collected.count < maxMessages && pagesRemaining > 0
        return collected.values.sorted(by: Self.chronological)
    }

    func loadOlder() async {
        guard let conversation, let nextBefore, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await repository.messages(
                in: conversation.id,
                page: MessagePageRequest(limit: 36, before: nextBefore)
            )
            guard self.conversation?.id == conversation.id else { return }
            let known = Set(messages.map(\.id))
            let older = page.messages.filter { !known.contains($0.id) }
            messages = (older + messages).sorted(by: Self.chronological)
            self.nextBefore = page.nextBefore
            if isFindPresented { recomputeFindMatches() }
        } catch {
            AppLog.ui.error("Older-message page failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func chronological(_ left: Message, _ right: Message) -> Bool {
        if left.createdAt == right.createdAt { return left.id.id < right.id.id }
        return left.createdAt < right.createdAt
    }
}

