import SwiftUI

struct ComposerView: View {
    @ObservedObject var model: ComposerModel
    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 9) {
                TextEditor(text: $model.text)
                    .riceFont(13)
                    .foregroundStyle(Rice.text)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 40 * scale, maxHeight: 110 * scale)
                    .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Rice.surface1, lineWidth: 1)
                    )
                    .disabled(model.conversationID == nil)
                    .onChange(of: model.text) { _, _ in model.textDidChange() }
                    .accessibilityLabel("Message draft")

                Button {
                    Task { await model.send() }
                } label: {
                    Group {
                        if model.isSending {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up")
                                .riceFont(13, .bold)
                                .foregroundStyle(canSend ? Rice.crust : Rice.overlay0)
                        }
                    }
                    .frame(width: 28 * scale, height: 28 * scale)
                    .background(canSend ? accent : Rice.surface0, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend || model.isSending)
                .help(model.isSendEnabled ? "Send (⌘↩)" : model.disabledExplanation)
                .accessibilityLabel("Send message")
            }

            if let feedback = model.sendFeedback {
                Text(feedback)
                    .riceFont(10)
                    .foregroundStyle(Rice.red)
                    .lineLimit(2)
            } else if !model.disabledExplanation.isEmpty {
                Text(model.disabledExplanation)
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Rice.base)
    }

    private var canSend: Bool {
        model.isSendEnabled && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
