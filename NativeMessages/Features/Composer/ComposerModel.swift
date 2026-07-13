import Foundation

@MainActor
final class ComposerModel: ObservableObject {
    @Published private(set) var conversationID: ConversationID?
    @Published var text = ""
    @Published private(set) var isSendEnabled = false
    @Published private(set) var isSending = false
    @Published private(set) var sendFeedback: String?
    @Published private(set) var disabledExplanation = "Select a conversation to write a draft."

    private let database: AppDatabase
    private var sendAction: ((String) async throws -> SendOutcome)?
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

    func select(
        _ conversationID: ConversationID?,
        capabilities: ProviderCapabilities,
        health: ProviderHealth,
        sendAction: ((String) async throws -> SendOutcome)?
    ) {
        saveTask?.cancel()
        restoreTask?.cancel()
        self.conversationID = conversationID
        self.sendAction = sendAction
        sendFeedback = nil
        isSendEnabled = conversationID != nil
            && sendAction != nil
            && CapabilityGate.canSend(capabilities: capabilities, health: health)
        if conversationID == nil {
            disabledExplanation = "Select a conversation to write a draft."
        } else if isSendEnabled {
            disabledExplanation = ""
        } else {
            disabledExplanation = "This provider cannot send; your draft is saved locally."
        }
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

    func send() async {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSendEnabled, !isSending, !body.isEmpty, let sendAction, let conversationID else { return }
        isSending = true
        defer { isSending = false }
        do {
            switch try await sendAction(body) {
            case .accepted, .confirmed:
                text = ""
                sendFeedback = nil
                saveTask?.cancel()
                try? await database.saveDraft("", conversationID: conversationID)
            case let .rejected(_, reason):
                sendFeedback = Self.feedback(for: reason)
            case .unknown:
                sendFeedback = "Send result unknown — check Messages.app before retrying."
            }
        } catch {
            sendFeedback = error.localizedDescription
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

    private static func feedback(for reason: UserFacingSendError) -> String {
        switch reason {
        case .unsupported:
            "This provider does not support sending."
        case .permissionDenied:
            "Automation permission denied — allow Native Messages to control Messages in System Settings → Privacy → Automation."
        case .invalidRequest:
            "The message could not be sent as written."
        case .providerUnavailable:
            "Messages.app rejected the send — check that it is signed in."
        case .manualVerificationRequired:
            "Sending needs manual verification for this provider."
        }
    }
}
