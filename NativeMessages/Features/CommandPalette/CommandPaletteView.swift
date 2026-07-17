import SwiftUI

/// The keyboard spine (⌘K): fuzzy-jump to any conversation or run any action.
/// Pounce-style floating panel over a dimmed backdrop, fully navigable with
/// ↑/↓ to move, Enter to invoke, Esc to close — no mouse required.
struct CommandPaletteView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("uiScale") private var uiScale = 1.0

    @FocusState private var isFieldFocused: Bool
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        // Query/selection live on the model so they survive a re-open and stay
        // a single source of truth for the keyboard handlers below.
        let items = PaletteRanking.items(query: model.paletteQuery, conversations: model.conversations, actions: actions)
        return ZStack(alignment: .top) {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                field
                if !items.isEmpty {
                    RiceDivider()
                    resultsList(items)
                }
            }
            .background(Rice.mantle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Rice.surface1, lineWidth: 1)
            )
            .frame(width: 560)
            .padding(.top, 90)
        }
        .transition(.opacity)
        .onAppear { isFieldFocused = true }
        .onChange(of: model.paletteQuery) { _, _ in model.paletteSelection = 0 }
        .onExitCommand { dismiss() }
        .onKeyPress(.upArrow) { moveSelection(-1, count: items.count); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1, count: items.count); return .handled }
    }

    private var field: some View {
        HStack(spacing: 9) {
            Image(systemName: "command")
                .riceFont(14)
                .foregroundStyle(Rice.subtext0)
            TextField("Jump to a conversation or run a command", text: $model.paletteQuery)
                .textFieldStyle(.plain)
                .riceFont(16)
                .foregroundStyle(Rice.text)
                .focused($isFieldFocused)
                .onSubmit { invokeSelection() }
            Text("esc")
                .riceFont(9, .medium)
                .foregroundStyle(Rice.overlay0)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Rice.surface0, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func resultsList(_ items: [PaletteItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PaletteRow(item: item, isSelected: index == model.paletteSelection)
                            .contentShape(Rectangle())
                            .onTapGesture { model.paletteSelection = index; invoke(item) }
                    }
                }
                .padding(6)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: PaletteHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            // Hug the content up to a cap so a short result set draws a tight
            // panel instead of a tall one padded with empty space.
            .frame(height: min(contentHeight, 360))
            .onPreferenceChange(PaletteHeightKey.self) { contentHeight = $0 }
            .onChange(of: model.paletteSelection) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id)
            }
        }
    }

    // MARK: - Actions catalog

    private var actions: [PaletteAction] {
        var catalog: [PaletteAction] = [
            PaletteAction(id: "new", title: "New Message", systemImage: "square.and.pencil", shortcut: "⌘N") {
                model.isComposePresented = true
            },
            PaletteAction(id: "search", title: "Search Messages…", systemImage: "magnifyingglass", shortcut: "⇧⌘F") {
                model.isSearchPresented = true
            },
            PaletteAction(
                id: "unread",
                title: model.showsUnreadOnly ? "Show All Conversations" : "Show Unread Only",
                systemImage: "line.3.horizontal.decrease.circle",
                shortcut: "⇧⌘U"
            ) {
                model.showsUnreadOnly.toggle()
            },
            PaletteAction(
                id: "needsReply",
                title: model.showsNeedsReplyOnly ? "Show All Conversations" : "Show Needs Reply",
                systemImage: "arrowshape.turn.up.left.circle",
                shortcut: "⇧⌘R"
            ) {
                model.showsNeedsReplyOnly.toggle()
            },
            PaletteAction(
                id: "sidebar",
                title: model.isSidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                systemImage: "sidebar.left",
                shortcut: "⌃⌘S"
            ) {
                model.toggleSidebar()
            },
            PaletteAction(id: "reload", title: "Reload", systemImage: "arrow.clockwise", shortcut: "⌘R") {
                model.load()
            },
        ]

        if let selected = model.selectedConversationID {
            let isVIP = model.isVIP(selected)
            catalog.append(
                PaletteAction(
                    id: "vip",
                    title: isVIP ? "Remove from VIP" : "Add to VIP",
                    systemImage: isVIP ? "star.slash" : "star",
                    shortcut: "⌃⌘V"
                ) {
                    model.toggleSelectedVIP()
                }
            )
            let pinned = model.pinnedIDs.contains(selected)
            catalog.append(
                PaletteAction(
                    id: "pin",
                    title: pinned ? "Unpin Conversation" : "Pin Conversation",
                    systemImage: pinned ? "pin.slash" : "pin",
                    shortcut: "⇧⌘P"
                ) {
                    model.toggleSelectedPin()
                }
            )
            let muted = model.isMuted(selected)
            catalog.append(
                PaletteAction(
                    id: "mute",
                    title: muted ? "Unmute Conversation" : "Mute Conversation",
                    systemImage: muted ? "bell" : "bell.slash",
                    shortcut: nil
                ) {
                    model.toggleMuted(selected)
                }
            )
            let archived = model.isArchived(selected)
            catalog.append(
                PaletteAction(
                    id: "archive",
                    title: archived ? "Unarchive Conversation" : "Archive Conversation",
                    systemImage: archived ? "tray.and.arrow.up" : "archivebox",
                    shortcut: nil
                ) {
                    model.toggleArchived(selected)
                }
            )
        }

        // Folder scope: clear (when active) + one filter action per folder, plus
        // a create action. Keeps folders reachable from the keyboard spine.
        if model.selectedFolderID != nil {
            catalog.append(
                PaletteAction(id: "folder-all", title: "Show All Messages", systemImage: "tray.full", shortcut: nil) {
                    model.selectFolder(nil)
                }
            )
        }
        for folder in model.folders {
            catalog.append(
                PaletteAction(id: "folder-\(folder.id)", title: "Filter: \(folder.name)", systemImage: "folder", shortcut: nil) {
                    model.selectFolder(folder.id)
                }
            )
        }
        catalog.append(
            PaletteAction(id: "new-folder", title: "New Folder…", systemImage: "folder.badge.plus", shortcut: nil) {
                model.folderEditor = .create(seed: nil)
            }
        )

        let other: ProviderMode = model.providerMode == .messages ? .fixture : .messages
        catalog.append(
            PaletteAction(id: "provider", title: "Switch to \(other.title)", systemImage: "arrow.left.arrow.right", shortcut: nil) {
                model.switchProvider(to: other)
            }
        )

        catalog.append(contentsOf: [
            PaletteAction(id: "zoomIn", title: "Zoom In", systemImage: "plus.magnifyingglass", shortcut: "⌘=") {
                uiScale = min(UIZoom.range.upperBound, uiScale + UIZoom.step)
            },
            PaletteAction(id: "zoomOut", title: "Zoom Out", systemImage: "minus.magnifyingglass", shortcut: "⌘-") {
                uiScale = max(UIZoom.range.lowerBound, uiScale - UIZoom.step)
            },
            PaletteAction(id: "zoomReset", title: "Actual Size", systemImage: "1.magnifyingglass", shortcut: "⌘0") {
                uiScale = 1.0
            },
            PaletteAction(id: "settings", title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                openSettings()
            },
        ])

        return catalog
    }

    // MARK: - Navigation

    private func moveSelection(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        model.paletteSelection = (model.paletteSelection + delta + count) % count
    }

    private func invokeSelection() {
        let items = PaletteRanking.items(query: model.paletteQuery, conversations: model.conversations, actions: actions)
        guard items.indices.contains(model.paletteSelection) else { return }
        invoke(items[model.paletteSelection])
    }

    private func invoke(_ item: PaletteItem) {
        switch item {
        case let .conversation(conversation):
            dismiss()
            model.select(conversation.id)
        case let .action(action):
            dismiss()
            action.perform()
        case let .searchMessages(text):
            dismiss()
            model.searchSeed = text
            model.isSearchPresented = true
        }
    }

    private func dismiss() {
        model.isPalettePresented = false
    }
}

// MARK: - Model

enum PaletteItem: Identifiable {
    case conversation(Conversation)
    case action(PaletteAction)
    case searchMessages(String)

    var id: String {
        switch self {
        case let .conversation(conversation): "c:\(conversation.id.id)"
        case let .action(action): "a:\(action.id)"
        case .searchMessages: "search-messages"
        }
    }
}

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let shortcut: String?
    let perform: () -> Void
}

private struct PaletteHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Row

private struct PaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool

    @Environment(\.riceAccent) private var accent

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .riceFont(13, .medium)
                    .foregroundStyle(Rice.text)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            isSelected ? accent.opacity(0.18) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var leading: some View {
        switch item {
        case let .conversation(conversation):
            AvatarView(conversation: conversation, size: 24)
        case let .action(action):
            glyph(action.systemImage)
        case .searchMessages:
            glyph("magnifyingglass")
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .riceFont(13)
            .foregroundStyle(Rice.subtext1)
            .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var trailing: some View {
        switch item {
        case let .conversation(conversation):
            ServiceChip(service: conversation.service)
        case let .action(action):
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .riceFont(10, .medium)
                    .foregroundStyle(Rice.overlay0)
            } else {
                categoryTag("action")
            }
        case .searchMessages:
            Image(systemName: "arrow.turn.down.left")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)
        }
    }

    private func categoryTag(_ text: String) -> some View {
        Text(text)
            .riceFont(9, .semibold)
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(Rice.overlay0)
    }

    private var title: String {
        switch item {
        case let .conversation(conversation): conversation.displayName
        case let .action(action): action.title
        case let .searchMessages(text): "Search messages “\(text)”…"
        }
    }

    private var subtitle: String? {
        switch item {
        case let .conversation(conversation):
            conversation.lastMessagePreview.isEmpty ? nil : conversation.lastMessagePreview
        case .action:
            nil
        case .searchMessages:
            "Full-text search across all conversations"
        }
    }
}
