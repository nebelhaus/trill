import Foundation

@MainActor
final class ComposerModel: ObservableObject {
    @Published private(set) var conversationID: ConversationID?
    @Published var text = ""
    @Published private(set) var pendingAttachments: [URL] = []
    @Published private(set) var isSendEnabled = false
    @Published private(set) var canSendAttachments = false
    @Published private(set) var isSending = false
    @Published private(set) var sendFeedback: String?
    @Published private(set) var disabledExplanation = "Select a conversation to write a draft."

    /// Snippet picker state. Non-empty `snippetMatches` means the `/`-trigger
    /// popover is showing; `snippetSelection` is the highlighted row. Both drive
    /// the `ComposerView` overlay and the `GrowingTextView` key routing.
    @Published private(set) var snippetMatches: [Snippet] = []
    @Published var snippetSelection = 0

    /// Template fill state. When a snippet carrying `{blank}` markers is inserted
    /// the composer enters a fill session: `isFillSessionActive` routes ⇥ / ⇧⇥
    /// to blank-to-blank navigation, and `pendingSelection` asks the text view
    /// to select the current blank. The session ends once the caret passes the
    /// last blank (or on send / conversation switch).
    @Published private(set) var isFillSessionActive = false
    @Published private(set) var pendingSelection: PendingSelection?

    /// A one-shot request for the `NSTextView` to select `range`. `token` bumps
    /// on every request so an identical range re-applies (e.g. re-selecting the
    /// same blank), and the view ignores a request it has already consumed.
    struct PendingSelection: Equatable {
        let range: NSRange
        let token: Int
    }

    private var selectionToken = 0

    private let database: AppDatabase
    private let snippets: SnippetStore
    private var sendAction: ((String, [URL]) async throws -> SendOutcome)?
    private var saveTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
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
    }

    func select(
        _ conversationID: ConversationID?,
        capabilities: ProviderCapabilities,
        health: ProviderHealth,
        sendAction: ((String, [URL]) async throws -> SendOutcome)?
    ) {
        saveTask?.cancel()
        restoreTask?.cancel()
        clearSnippetPicker()
        endFillSession()
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
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = pendingAttachments
        guard isSendEnabled, !isSending, !body.isEmpty || !files.isEmpty,
              let sendAction, let conversationID else { return }
        isSending = true
        defer { isSending = false }
        do {
            switch try await sendAction(body, files) {
            case .accepted, .confirmed:
                text = ""
                pendingAttachments = []
                clearSnippetPicker()
                endFillSession()
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
                endFillSession()
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
        // UTF-16 offset where the body lands, so we can find its blanks by
        // NSRange once it's spliced into the full draft.
        let insertion = text[..<range.lowerBound].utf16.count
        text.replaceSubrange(range, with: body)
        clearSnippetPicker()
        beginFillSession(from: insertion)
        return true
    }

    func clearSnippetPicker() {
        if !snippetMatches.isEmpty { snippetMatches = [] }
        snippetSelection = 0
        snippetTriggerRange = nil
    }

    // MARK: - Template fill

    /// Select the first blank of a just-inserted template; if the snippet has no
    /// blanks, this is a no-op and the caret stays where the text view parks it.
    private func beginFillSession(from location: Int) {
        guard let first = MessageTemplate.nextPlaceholder(in: text, from: location) else {
            endFillSession()
            return
        }
        isFillSessionActive = true
        requestSelection(first)
    }

    /// ⇥ while filling: select the next blank at or after `caret`, or end the
    /// session (caret to the end) once there are none left. `caret` is the live
    /// selection's trailing edge, so a blank the user just typed over is skipped.
    /// Returns whether the key was consumed.
    @discardableResult
    func advanceFill(from caret: Int) -> Bool {
        guard isFillSessionActive else { return false }
        if let next = MessageTemplate.nextPlaceholder(in: text, from: caret) {
            requestSelection(next)
        } else {
            endFillSession()
            requestSelection(NSRange(location: (text as NSString).length, length: 0))
        }
        return true
    }

    /// ⇧⇥ while filling: select the previous blank before `caret`; stays on the
    /// first when there's nothing earlier. Returns whether the key was consumed.
    @discardableResult
    func retreatFill(from caret: Int) -> Bool {
        guard isFillSessionActive else { return false }
        if let previous = MessageTemplate.previousPlaceholder(in: text, before: caret) {
            requestSelection(previous)
        }
        return true
    }

    private func endFillSession() {
        if isFillSessionActive { isFillSessionActive = false }
    }

    private func requestSelection(_ range: NSRange) {
        selectionToken += 1
        pendingSelection = PendingSelection(range: range, token: selectionToken)
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
