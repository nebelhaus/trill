import SwiftUI

/// Manage canned responses: add, edit inline, or delete. Edits persist to the
/// `SnippetStore` as you type; the store writes to SQLite off the main actor.
struct SnippetSettingsView: View {
    @EnvironmentObject private var store: SnippetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Snippets")
                    .riceSectionHeader()
                Spacer()
                Button {
                    store.addBlank()
                } label: {
                    Label("New", systemImage: "plus")
                }
                .buttonStyle(RiceSubtleButtonStyle())
            }
            Text("Type / in the composer, then a keyword, to insert one. ↑↓ pick · ↵ insert.")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)

            if store.snippets.isEmpty {
                Text("No snippets yet — add one to reuse a reply.")
                    .riceFont(11)
                    .foregroundStyle(Rice.subtext0)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.snippets) { snippet in
                        SnippetEditRow(
                            snippet: snippet,
                            onChange: { store.update($0) },
                            onDelete: { store.delete(snippet) }
                        )
                    }
                }
            }
        }
    }
}

/// One editable snippet. Local `@State` holds the in-progress edit so a store
/// update (which touches `updatedAt`) never yanks focus mid-keystroke; changes
/// flow back to the store on every edit.
private struct SnippetEditRow: View {
    let snippet: Snippet
    let onChange: (Snippet) -> Void
    let onDelete: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var title: String
    @State private var messageText: String

    init(snippet: Snippet, onChange: @escaping (Snippet) -> Void, onDelete: @escaping () -> Void) {
        self.snippet = snippet
        self.onChange = onChange
        self.onDelete = onDelete
        _title = State(initialValue: snippet.title)
        _messageText = State(initialValue: snippet.body)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("/")
                .riceFont(12, .semibold)
                .foregroundStyle(accent)
                .padding(.top, 6)
            VStack(spacing: 5) {
                TextField("keyword", text: $title)
                    .textFieldStyle(.plain)
                    .riceFont(12, .semibold)
                    .foregroundStyle(Rice.text)
                    .onChange(of: title) { _, _ in commit() }
                TextField("Message text", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .riceFont(11)
                    .foregroundStyle(Rice.subtext1)
                    .lineLimit(1...4)
                    .onChange(of: messageText) { _, _ in commit() }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .riceFont(11)
            }
            .buttonStyle(RiceIconButtonStyle())
            .help("Delete snippet")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Rice.surface0.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func commit() {
        onChange(Snippet(id: snippet.id, title: title, body: messageText))
    }
}
