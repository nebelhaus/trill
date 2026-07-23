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

    /// Completion picker state. Non-empty `completions` means the `/`-trigger
    /// popover is showing; `completionSelection` is the highlighted row. The list
    /// blends built-in slash commands with the user's snippets. Both drive the
    /// `ComposerView` overlay and the `GrowingTextView` key routing.
    @Published private(set) var completions: [CompletionItem] = []
    @Published var completionSelection = 0

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

    /// Called on the main actor after a draft is written or cleared, reporting
    /// the conversation and whether it now holds any text. Lets the inbox keep
    /// its Drafts filter in sync without polling the database. `hasContent`
    /// makes the update idempotent — the observer inserts or removes, never
    /// needing to know the prior state.
    var onDraftChanged: ((ConversationID, _ hasContent: Bool) -> Void)?

    /// Called on the main actor once a send is accepted (or maybe-sent), with the
    /// conversation it went to. Lets the open timeline snap to the newly-sent
    /// message as it lands from the provider — the send call returns before the
    /// row shows up in `chat.db`, so the timeline follows the tail until it does.
    var onSent: ((ConversationID) -> Void)?

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
    /// Range of the live `/token` in `text`, replaced when a completion is picked.
    private var completionTriggerRange: Range<String.Index>?

    init(database: AppDatabase, snippets: SnippetStore) {
        self.database = database
        self.snippets = snippets
    }

    var isCompletionPickerActive: Bool { !completions.isEmpty }

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
        // A held send owns the outgoing thread's draft lifecycle (dispatchDetached
        // clears or restores it), and the visible text *is* that message, not a
        // draft — so skip the draft persistence below in that case.
        let dispatchingPendingSend = pendingSend != nil
        if let pending = pendingSend {
            undoTimerTask?.cancel()
            undoTimerTask = nil
            pendingSend = nil
            undoSecondsRemaining = nil
            dispatchDetached(pending)
        }
        // Persist the outgoing draft now instead of dropping its pending
        // debounce — switching away must never lose text typed in the last
        // 250ms. Fire-and-forget: we're leaving this thread, so there's no need
        // to block. Keyed on `self.conversationID` — the thread we're *leaving*,
        // not the `conversationID` parameter we're switching *to*.
        if let outgoing = self.conversationID, !isRestoring, !dispatchingPendingSend {
            let value = text
            saveTask?.cancel()
            Task { [database] in
                try? await database.saveDraft(value, conversationID: outgoing)
            }
            onDraftChanged?(outgoing, !value.isEmpty)
        } else {
            saveTask?.cancel()
        }
        restoreTask?.cancel()
        clearCompletions()
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
        clearCompletions()
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
        Task { [database, weak self] in
            do {
                switch try await pending.send(pending.body, pending.files) {
                case .accepted, .confirmed, .unknown:
                    try? await database.saveDraft("", conversationID: pending.conversationID)
                    self?.onDraftChanged?(pending.conversationID, false)
                case .rejected:
                    try? await database.saveDraft(pending.body, conversationID: pending.conversationID)
                    self?.onDraftChanged?(pending.conversationID, !pending.body.isEmpty)
                }
            } catch {
                try? await database.saveDraft(pending.body, conversationID: pending.conversationID)
                self?.onDraftChanged?(pending.conversationID, !pending.body.isEmpty)
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
                clearCompletions()
                endFillSession()
                sendFeedback = nil
                saveTask?.cancel()
                try? await database.saveDraft("", conversationID: conversationID)
                onDraftChanged?(conversationID, false)
                onSent?(conversationID)
            case let .rejected(_, reason):
                sendFeedback = Self.feedback(for: reason)
            case .unknown:
                // Part of the draft may have reached Messages.app; clear it so
                // a retry can't duplicate what already went out.
                text = ""
                pendingAttachments = []
                clearCompletions()
                endFillSession()
                saveTask?.cancel()
                try? await database.saveDraft("", conversationID: conversationID)
                onDraftChanged?(conversationID, false)
                onSent?(conversationID)
                sendFeedback = "Some of the message may not have sent — check Messages.app."
            }
        } catch {
            sendFeedback = error.localizedDescription
        }
    }

    func textDidChange() {
        guard !isRestoring, let conversationID else { return }
        refreshCompletions()
        let value = text
        saveTask?.cancel()
        saveTask = Task { [database, weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await database.saveDraft(value, conversationID: conversationID)
                self?.onDraftChanged?(conversationID, !value.isEmpty)
            } catch is CancellationError {
                return
            } catch {
                AppLog.database.error("Draft persistence failed error=\(String(describing: type(of: error)), privacy: .public)")
            }
        }
    }

    /// Persist the current draft synchronously, bypassing the 250ms debounce.
    /// Called on app termination: text typed in the last debounce window lives
    /// only in a pending `saveTask`, which quitting would cancel unfired — so
    /// without this the last few keystrokes before ⌘Q are lost. Blocks the
    /// caller until the write lands (bounded, so a stuck write can't wedge
    /// termination), because once we return the process may exit immediately.
    func flushDraft() {
        guard !isRestoring, let conversationID else { return }
        saveTask?.cancel()
        let value = text
        let done = DispatchSemaphore(value: 0)
        // Detached, not a plain `Task {}`: this method is @MainActor, so a
        // main-actor-isolated task would resume its continuation on the main
        // thread — which is blocked on `done.wait()` below — and deadlock.
        Task.detached { [database] in
            try? await database.saveDraft(value, conversationID: conversationID)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    // MARK: - Completions (slash commands + snippets)

    /// Re-evaluate the `/`-trigger against the current text on every keystroke.
    /// Shows the picker when the trailing token is a `/query` that ranks at least
    /// one built-in command or usable snippet; hides it otherwise.
    private func refreshCompletions() {
        guard let match = SnippetTrigger.parse(text) else {
            clearCompletions()
            return
        }
        let results = CompletionRanking.matches(
            query: match.query,
            commands: SlashCommand.all,
            snippets: snippets.snippets
        )
        guard !results.isEmpty else {
            clearCompletions()
            return
        }
        completionTriggerRange = match.range
        completions = results
        if completionSelection >= results.count { completionSelection = 0 }
    }

    func moveCompletionSelection(_ delta: Int) {
        let count = completions.count
        guard count > 0 else { return }
        completionSelection = (completionSelection + delta + count) % count
    }

    /// Insert the highlighted completion, replacing the `/token` that triggered
    /// it. A slash command expands to its (possibly dynamic) text; a snippet
    /// copies its body and may open a fill session for `{blank}` templates.
    /// Returns `false` when there's nothing to commit so the caller (the text
    /// view's Return handler) can fall through to its normal behavior.
    @discardableResult
    func commitSelectedCompletion() -> Bool {
        guard completions.indices.contains(completionSelection),
              let range = completionTriggerRange else { return false }
        let item = completions[completionSelection]
        // UTF-16 offset where the inserted text lands, so a template's blanks can
        // be found by NSRange once spliced into the full draft.
        let insertion = text[..<range.lowerBound].utf16.count
        text.replaceSubrange(range, with: item.resolvedText())
        clearCompletions()
        if item.isCommand {
            endFillSession()
        } else {
            beginFillSession(from: insertion)
        }
        return true
    }

    func clearCompletions() {
        if !completions.isEmpty { completions = [] }
        completionSelection = 0
        completionTriggerRange = nil
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
