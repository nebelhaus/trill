import SwiftUI

/// Command-palette style search overlay (⌘K), pounce-style: floating flat
/// panel over a dimmed backdrop.
struct SearchView: View {
    @ObservedObject var model: InboxModel
    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            panel
                .frame(width: 560)
                .padding(.top, 90)
        }
        .transition(.opacity)
        .onExitCommand { dismiss() }
        .onDisappear { searchTask?.cancel() }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .riceFont(14)
                    .foregroundStyle(Rice.subtext0)
                TextField("Search messages", text: $query)
                    .textFieldStyle(.plain)
                    .riceFont(16)
                    .foregroundStyle(Rice.text)
                    .focused($isFieldFocused)
                    .onSubmit { openFirstResult() }
                Text("esc")
                    .riceFont(9, .medium)
                    .foregroundStyle(Rice.overlay0)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Rice.surface0, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if !trimmedQuery.isEmpty {
                RiceDivider()
                results
            }
        }
        .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Rice.surface1, lineWidth: 1)
        )
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                await model.search(text: query)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.searchResults.isEmpty {
            Text("No results for “\(trimmedQuery)”")
                .riceFont(12)
                .foregroundStyle(Rice.subtext0)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.searchResults) { message in
                        SearchResultRow(
                            title: conversationTitle(for: message.conversationID),
                            message: message
                        ) {
                            open(message)
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openFirstResult() {
        guard let first = model.searchResults.first else { return }
        open(first)
    }

    private func open(_ message: Message) {
        model.select(message.conversationID)
        dismiss()
    }

    private func dismiss() {
        searchTask?.cancel()
        model.isSearchPresented = false
    }

    private func conversationTitle(for id: ConversationID) -> String {
        model.conversations.first(where: { $0.id == id })?.displayName ?? "Conversation"
    }
}

private struct SearchResultRow: View {
    let title: String
    let message: Message
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title)
                        .riceFont(12, .semibold)
                        .foregroundStyle(Rice.text)
                    Spacer()
                    Text(message.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .riceFont(9)
                        .foregroundStyle(Rice.overlay0)
                }
                Text(message.text.isEmpty ? "Attachment" : message.text)
                    .riceFont(11)
                    .foregroundStyle(Rice.subtext0)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isHovering ? Rice.surface0.opacity(0.7) : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
