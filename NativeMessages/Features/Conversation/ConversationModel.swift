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

    private var repository: MessagesRepository
    private var loadTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(repository: MessagesRepository) {
        self.repository = repository
    }

    deinit {
        loadTask?.cancel()
        refreshTask?.cancel()
    }

    func updateRepository(_ repository: MessagesRepository) {
        loadTask?.cancel()
        self.repository = repository
        clear()
    }

    func clear() {
        loadTask?.cancel()
        refreshTask?.cancel()
        conversation = nil
        messages = []
        nextBefore = nil
        state = .idle
    }

    func select(_ conversation: Conversation) {
        loadTask?.cancel()
        self.conversation = conversation
        messages = []
        nextBefore = nil
        state = .loading
        let repository = repository
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await repository.messages(in: conversation.id, page: MessagePageRequest(limit: 36))
                guard !Task.isCancelled, self.conversation?.id == conversation.id else { return }
                messages = page.messages.sorted(by: Self.chronological)
                nextBefore = page.nextBefore
                state = messages.isEmpty ? .empty : .loaded
                startPeriodicRefresh()
            } catch is CancellationError {
                return
            } catch {
                guard self.conversation?.id == conversation.id else { return }
                state = .failed
                AppLog.ui.error("Conversation load failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Delivery/read flags and attachment transfers mutate existing chat.db
    /// rows, which the new-row event poller cannot see. Periodically re-fetch
    /// the newest page and merge changes in place.
    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                await self?.refreshRecent()
            }
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
    }

    /// Merges a message arriving from the live event stream.
    func appendLive(_ message: Message) {
        guard conversation?.id == message.conversationID else { return }
        guard state == .loaded || state == .empty else { return }
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages = (messages + [message]).sorted(by: Self.chronological)
        state = .loaded
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
        } catch {
            AppLog.ui.error("Older-message page failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private static func chronological(_ left: Message, _ right: Message) -> Bool {
        if left.createdAt == right.createdAt { return left.id.id < right.id.id }
        return left.createdAt < right.createdAt
    }
}

