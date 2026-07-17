import SwiftUI

/// ⌘N sheet: pick a contact (or type any phone/email) and write the first
/// message. Choosing someone with an existing 1:1 thread opens that thread
/// instead of blind-sending a duplicate conversation.
struct ComposeSheet: View {
    @ObservedObject var model: InboxModel
    @Environment(\.riceAccent) private var accent

    @State private var recipientQuery = ""
    @State private var chosen: ContactSuggestion?
    @State private var suggestions: [ContactSuggestion] = []
    @State private var messageText = ""
    @State private var isSending = false
    @State private var feedback: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focus: Field?

    private enum Field {
        case recipient
        case message
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message")
                .riceSectionHeader()

            recipientRow

            if chosen == nil, !suggestions.isEmpty {
                suggestionList
            }

            TextEditor(text: $messageText)
                .riceFont(13)
                .foregroundStyle(Rice.text)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 88)
                .background(Rice.crust.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Rice.surface1, lineWidth: 1)
                )
                .focused($focus, equals: .message)
                .accessibilityLabel("First message")

            if let feedback {
                Text(feedback)
                    .riceFont(10)
                    .foregroundStyle(Rice.red)
                    .lineLimit(2)
            } else if !model.canCompose {
                Text("This provider cannot send.")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.isComposePresented = false }
                    .buttonStyle(RiceSubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    send()
                } label: {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .buttonStyle(RiceProminentButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || isSending)
                .help("Send (⌘↩)")
            }
        }
        .padding(18)
        .frame(width: 440)
        .background(Rice.mantle)
        .onAppear { focus = .recipient }
        .onDisappear { searchTask?.cancel() }
    }

    @ViewBuilder
    private var recipientRow: some View {
        HStack(spacing: 8) {
            Text("To:")
                .riceFont(12, .medium)
                .foregroundStyle(Rice.subtext0)
            if let chosen {
                HStack(spacing: 6) {
                    Text(chosen.name)
                        .riceFont(12, .medium)
                        .foregroundStyle(Rice.text)
                    Text(chosen.handle)
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                    Button {
                        self.chosen = nil
                        focus = .recipient
                    } label: {
                        Image(systemName: "xmark")
                            .riceFont(8, .bold)
                            .foregroundStyle(Rice.subtext0)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove recipient")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(accent.opacity(0.18), in: Capsule())
                Spacer()
            } else {
                TextField("Name, phone, or email", text: $recipientQuery)
                    .textFieldStyle(.plain)
                    .riceFont(13)
                    .foregroundStyle(Rice.text)
                    .focused($focus, equals: .recipient)
                    .onSubmit { commitRawRecipient() }
                    .onChange(of: recipientQuery) { _, term in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(for: .milliseconds(150))
                            guard !Task.isCancelled else { return }
                            suggestions = await model.contactSuggestions(matching: term)
                        }
                    }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Rice.crust.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Rice.surface1, lineWidth: 1)
        )
    }

    private var suggestionList: some View {
        VStack(spacing: 1) {
            ForEach(suggestions) { suggestion in
                Button {
                    choose(suggestion)
                } label: {
                    HStack {
                        Text(suggestion.name)
                            .riceFont(12, .medium)
                            .foregroundStyle(Rice.text)
                        Spacer()
                        Text(suggestion.handle)
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext0)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Rice.crust.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func choose(_ suggestion: ContactSuggestion) {
        if let existing = model.existingDirectConversation(handle: suggestion.handle) {
            model.select(existing.id)
            model.isComposePresented = false
            return
        }
        chosen = suggestion
        suggestions = []
        recipientQuery = ""
        focus = .message
    }

    /// Pressing return with a raw phone/email typed uses it directly.
    private func commitRawRecipient() {
        let raw = recipientQuery.trimmingCharacters(in: .whitespaces)
        guard looksLikeHandle(raw) else { return }
        choose(ContactSuggestion(name: raw, handle: raw))
    }

    private func looksLikeHandle(_ value: String) -> Bool {
        if value.contains("@") { return value.contains(".") }
        return value.filter(\.isNumber).count >= 7
    }

    private var canSend: Bool {
        model.canCompose
            && chosen != nil
            && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard let chosen, canSend else { return }
        isSending = true
        feedback = nil
        Task {
            let outcome = await model.sendDirect(handle: chosen.handle, text: messageText)
            isSending = false
            switch outcome {
            case .accepted, .confirmed:
                model.isComposePresented = false
            case let .rejected(_, reason):
                feedback = Self.feedback(for: reason)
            case .unknown:
                feedback = "The message may not have sent — check Messages.app."
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
            "Messages.app rejected the send — the address may not be reachable."
        case .manualVerificationRequired:
            "Sending needs manual verification for this provider."
        }
    }
}
