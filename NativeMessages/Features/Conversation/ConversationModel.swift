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

    init(repository: MessagesRepository) {
        self.repository = repository
    }

    deinit { loadTask?.cancel() }

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
            } catch is CancellationError {
                return
            } catch {
                guard self.conversation?.id == conversation.id else { return }
                state = .failed
                AppLog.ui.error("Conversation load failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
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

