import Foundation

@MainActor
final class ComposerModel: ObservableObject {
    @Published private(set) var conversationID: ConversationID?
    @Published var text = ""
    @Published private(set) var pendingAttachments: [URL] = []
    @Published private(set) var isSendEnabled = false
    @Published private(set) var canSendAttachments = false
    @Published private(set) var isSending = false
    /// Non-nil while a just-sent message is held in the undo window, counting
    /// down the seconds before it actually dispatches. Drives the composer's
    /// locked state and the Undo affordance.
    @Published private(set) var undoSecondsRemaining: Int?
    @Published private(set) var sendFeedback: String?
    @Published private(set) var disabledExplanation = "Select a conversation to write a draft."

    /// Snippet picker state. Non-empty `snippetMatches` means the `/`-trigger
    /// popover is showing; `snippetSelection` is the highlighted row. Both drive
    /// the `ComposerView` overlay and the `GrowingTextView` key routing.
    @Published private(set) var snippetMatches: [Snippet] = []
    @Published var snippetSelection = 0

    private let database: AppDatabase
    private let snippets: SnippetStore
    private var sendAction: ((String, [URL]) async throws -> SendOutcome)?
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var pendingSend: PendingSend?
    private var undoTimerTask: Task<Void, Never>?

    /// How long an outgoing message is held before it actually dispatches,
    /// giving a window to undo an accidental send. Off unless the `undoSend`
    /// setting is enabled (the default).
    private static let undoWindowSeconds = 5

    /// A held send, captured whole so it can dispatch to its original
    /// conversation even after the composer has moved on to another thread.
    private struct PendingSend {
        let body: String
        let files: [URL]
        let conversationID: ConversationID
        let send: (String, [URL]) async throws -> SendOutcome
    }

    private static var undoSendEnabled: Bool {
        UserDefaults.standard.object(forKey: "undoSend") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "undoSend")
    }
    private var isRestoring = false
    /// Range of the live `/token` in `text`, replaced when a snippet is picked.
    private var snippetTriggerRange: Range<String.Index>?

    init(database: AppDatabase, snippets: SnippetStore) {
        self.database = database
        self.snippets = snippets
    }

    var isSnippetPickerActive: Bool { !snippetMatches.isEmpty }

    deinit {
        saveTask?.cancel()
        restoreTask?.cancel()
        undoTimerTask?.cancel()
    }

    func select(
        _ conversationID: ConversationID?,
        capabilities: ProviderCapabilities,
        health: ProviderHealth,
        sendAction: ((String, [URL]) async throws -> SendOutcome)?
    ) {
        // Leaving the thread that has a message in its undo window: dispatch it
        // now, in the background, so switching conversations never drops a send.
        if let pending = pendingSend {
            undoTimerTask?.cancel()
            undoTimerTask = nil
            pendingSend = nil
            undoSecondsRemaining = nil
            dispatchDetached(pending)
        }
        saveTask?.cancel()
        restoreTask?.cancel()
        clearSnippetPicker()
        self.conversationID = conversationID
        self.sendAction = sendAction
        sendFeedback = nil
        pendingAttachments = []
        isSendEnabled = conversationID != nil
            && sendAction != nil
            && CapabilityGate.canSend(capabilities: capabilities, health: health)
        canSendAttachments = isSendEnabled && capabilities.supports(.sendAttachments)
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

    func stageAttachments(_ urls: [URL]) {
        guard canSendAttachments else { return }
        let incoming = urls.filter { url in
            url.isFileURL
                && FileManager.default.fileExists(atPath: url.path)
                && !pendingAttachments.contains(url)
        }
        guard !incoming.isEmpty else { return }
        pendingAttachments += incoming
        sendFeedback = nil
    }

    func removeAttachment(_ url: URL) {
        pendingAttachments.removeAll { $0 == url }
    }

    func send() async {
        // A second send while one is already held simply dispatches it now.
        if pendingSend != nil {
            await flushPendingSend()
            return
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingAttachments
        guard isSendEnabled, !isSending, !body.isEmpty || !files.isEmpty,
              let sendAction, let conversationID else { return }
        guard Self.undoSendEnabled else {
            await performSend(body: body, files: files, conversationID: conversationID, sendAction: sendAction)
            return
        }
        beginUndoWindow(body: body, files: files, conversationID: conversationID, sendAction: sendAction)
    }

    /// Cancel a held send and hand the message back to the composer, untouched,
    /// so the user can edit it or drop it.
    func undoPendingSend() {
        undoTimerTask?.cancel()
        undoTimerTask = nil
        pendingSend = nil
        undoSecondsRemaining = nil
    }

    /// Dispatch a held send immediately, skipping the rest of the window.
    func flushPendingSend() async {
        undoTimerTask?.cancel()
        undoTimerTask = nil
        await firePendingSend()
    }

    private func beginUndoWindow(
        body: String,
        files: [URL],
        conversationID: ConversationID,
        sendAction: @escaping (String, [URL]) async throws -> SendOutcome
    ) {
        pendingSend = PendingSend(body: body, files: files, conversationID: conversationID, send: sendAction)
        undoSecondsRemaining = Self.undoWindowSeconds
        sendFeedback = nil
        clearSnippetPicker()
        undoTimerTask = Task { [weak self] in
            for remaining in stride(from: Self.undoWindowSeconds - 1, through: 0, by: -1) {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return // cancelled by undo/flush, which owns the state
                }
                guard let self, !Task.isCancelled else { return }
                if remaining == 0 {
                    await self.firePendingSend()
                } else {
                    self.undoSecondsRemaining = remaining
                }
            }
        }
    }

    private func firePendingSend() async {
        guard let pending = pendingSend else { return }
        pendingSend = nil
        undoSecondsRemaining = nil
        undoTimerTask = nil
        await performSend(
            body: pending.body,
            files: pending.files,
            conversationID: pending.conversationID,
            sendAction: pending.send
        )
    }

    /// Fire a held send for a conversation the composer is navigating away from.
    /// Runs without touching the visible composer (which is loading a different
    /// thread); on failure the draft is restored so the message is never lost.
    private func dispatchDetached(_ pending: PendingSend) {
        Task { [database] in
            do {
                switch try await pending.send(pending.body, pending.files) {
                case .accepted, .confirmed, .unknown:
                    try? await database.saveDraft("", conversationID: pending.conversationID)
                case .rejected:
                    try? await database.saveDraft(pending.body, conversationID: pending.conversationID)
                }
            } catch {
                try? await database.saveDraft(pending.body, conversationID: pending.conversationID)
            }
        }
    }

    private func performSend(
        body: String,
        files: [URL],
        conversationID: ConversationID,
        sendAction: (String, [URL]) async throws -> SendOutcome
    ) async {
        isSending = true
        defer { isSending = false }
        do {
            switch try await sendAction(body, files) {
            case .accepted, .confirmed:
                text = ""
                pendingAttachments = []
                clearSnippetPicker()
                sendFeedback = nil
                saveTask?.cancel()
                try? await database.saveDraft("", conversationID: conversationID)
            case let .rejected(_, reason):
                sendFeedback = Self.feedback(for: reason)
            case .unknown:
                // Part of the draft may have reached Messages.app; clear it so
                // a retry can't duplicate what already went out.
                text = ""
                pendingAttachments = []
                clearSnippetPicker()
                saveTask?.cancel()
                try? await database.saveDraft("", conversationID: conversationID)
                sendFeedback = "Some of the message may not have sent — check Messages.app."
            }
        } catch {
            sendFeedback = error.localizedDescription
        }
    }

    func textDidChange() {
        guard !isRestoring, let conversationID else { return }
        refreshSnippetPicker()
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

    // MARK: - Snippets

    /// Re-evaluate the `/`-trigger against the current text on every keystroke.
    /// Shows the picker when the trailing token is a `/query` that ranks at
    /// least one usable snippet; hides it otherwise.
    private func refreshSnippetPicker() {
        guard let match = SnippetTrigger.parse(text) else {
            clearSnippetPicker()
            return
        }
        let results = SnippetRanking.matches(query: match.query, snippets: snippets.snippets)
        guard !results.isEmpty else {
            clearSnippetPicker()
            return
        }
        snippetTriggerRange = match.range
        snippetMatches = results
        if snippetSelection >= results.count { snippetSelection = 0 }
    }

    func moveSnippetSelection(_ delta: Int) {
        let count = snippetMatches.count
        guard count > 0 else { return }
        snippetSelection = (snippetSelection + delta + count) % count
    }

    /// Insert the highlighted snippet, replacing the `/token` that triggered it.
    /// Returns `false` when there's nothing to commit so the caller (the text
    /// view's Return handler) can fall through to its normal behavior.
    @discardableResult
    func commitSelectedSnippet() -> Bool {
        guard snippetMatches.indices.contains(snippetSelection),
              let range = snippetTriggerRange else { return false }
        let body = snippetMatches[snippetSelection].body
        text.replaceSubrange(range, with: body)
        clearSnippetPicker()
        return true
    }

    func clearSnippetPicker() {
        if !snippetMatches.isEmpty { snippetMatches = [] }
        snippetSelection = 0
        snippetTriggerRange = nil
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
