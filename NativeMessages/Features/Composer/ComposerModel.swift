import Foundation

@MainActor
final class ComposerModel: ObservableObject {
    @Published private(set) var conversationID: ConversationID?
    @Published var text = ""
    @Published private(set) var isSendEnabled = false
    @Published private(set) var disabledExplanation = "Select a conversation to write a draft."

    private let database: AppDatabase
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var isRestoring = false

    init(database: AppDatabase) {
        self.database = database
    }

    deinit {
        saveTask?.cancel()
        restoreTask?.cancel()
    }

    func select(_ conversationID: ConversationID?, capabilities: ProviderCapabilities, health: ProviderHealth) {
        saveTask?.cancel()
        restoreTask?.cancel()
        self.conversationID = conversationID
        isSendEnabled = conversationID != nil && CapabilityGate.canSend(capabilities: capabilities, health: health)
        disabledExplanation = conversationID == nil
            ? "Select a conversation to write a draft."
            : "Sending is safety-gated in this foundation build; your draft is saved locally."
        guard let conversationID else {
            text = ""
            return
        }
        isRestoring = true
        restoreTask = Task { [weak self] in
            guard let self else { return }
            let restored = (try? await database.draft(conversationID: conversationID)) ?? ""
            guard !Task.isCancelled, self.conversationID == conversationID else { return }
            text = restored
            isRestoring = false
        }
    }

    func textDidChange() {
        guard !isRestoring, let conversationID else { return }
        let value = text
        saveTask?.cancel()
        saveTask = Task { [database] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await database.saveDraft(value, conversationID: conversationID)
            } catch is CancellationError {
                return
            } catch {
                AppLog.database.error("Draft persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }
}
