import AppKit
import SwiftUI

struct InboxView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("displayDensity") private var densityRaw = DisplayDensity.comfortable.rawValue

    private var density: DisplayDensity {
        DisplayDensity(rawValue: densityRaw) ?? .comfortable
    }

    @AppStorage("sidebarWidth") private var sidebarWidth = 288.0
    @State private var liveSidebarWidth: Double?
    @State private var dragStartWidth: Double?

    private static let minSidebarWidth: Double = 220
    private static let maxSidebarWidth: Double = 460

    /// Below this window width the two-pane layout can't give both panes a
    /// usable share, so we fold to a single column (list *or* thread, like a
    /// responsive site's off-canvas nav). Sized so a half-screen split on a
    /// laptop stays two-pane while a docked ~1/3 slice goes compact.
    private static let compactBreakpoint: CGFloat = 620

    var body: some View {
        GeometryReader { proxy in
            let isCompact = proxy.size.width < Self.compactBreakpoint
            Group {
                if isCompact {
                    compactBody
                } else {
                    regularBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Rice.mantle)
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.16), value: model.isSidebarVisible)
            .animation(.easeOut(duration: 0.18), value: isCompact)
            .animation(.easeOut(duration: 0.18), value: model.selectedConversationID)
            .overlay {
                if model.isSearchPresented {
                    SearchView(model: model)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.isSearchPresented)
            .overlay {
                if model.isPalettePresented {
                    CommandPaletteView(model: model)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.isPalettePresented)
            .overlay {
                if model.isLibraryPresented {
                    UniversalLibraryView(model: model)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.isLibraryPresented)
            .overlay {
                if model.isShortcutsPresented {
                    ShortcutCheatSheetView(model: model)
                }
            }
            .animation(.easeOut(duration: 0.12), value: model.isShortcutsPresented)
            .sheet(isPresented: $model.isComposePresented) {
                ComposeSheet(model: model)
            }
            .sheet(item: $model.folderEditor) { mode in
                FolderEditorView(model: model, mode: mode)
            }
            .task { model.load() }
            .onChange(of: model.selectedConversationID) { _, selection in
                model.select(selection)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, model.providerMode == .messages {
                    model.load()
                }
            }
        }
    }

    // MARK: - Layouts

    /// Two-pane: resizable sidebar beside the detail, today's desktop layout.
    private var regularBody: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarView(model: model, density: density)
                    .frame(width: liveSidebarWidth ?? sidebarWidth)
                    .transition(.move(edge: .leading))
                SidebarResizeHandle()
                    .gesture(
                        // Global coordinate space: with local coordinates the
                        // handle moves under the cursor mid-drag and feeds its
                        // own translation back, which jitters. Width persists
                        // to AppStorage only when the drag ends.
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartWidth ?? sidebarWidth
                                if dragStartWidth == nil { dragStartWidth = start }
                                liveSidebarWidth = min(
                                    max(start + Double(value.translation.width), Self.minSidebarWidth),
                                    Self.maxSidebarWidth
                                )
                            }
                            .onEnded { _ in
                                if let liveSidebarWidth {
                                    sidebarWidth = liveSidebarWidth
                                }
                                liveSidebarWidth = nil
                                dragStartWidth = nil
                            }
                    )
            }

            detail(isCompact: false)
        }
    }

    /// Single column: the list, or the open thread with a back button. The
    /// sidebar toggle / resize handle are meaningless here, so they're gone.
    private var compactBody: some View {
        Group {
            if compactShowsDetail {
                detail(isCompact: true)
                    .transition(.move(edge: .trailing))
            } else {
                SidebarView(model: model, density: density, isCompact: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Rice.mantle)
                    .transition(.move(edge: .leading))
            }
        }
    }

    /// In compact mode, show the thread when one is picked — and also when the
    /// provider is in a recovery/loading state, so its full-screen recovery
    /// view surfaces instead of the sidebar's cramped mini-notice.
    private var compactShowsDetail: Bool {
        if model.selectedConversationID != nil { return true }
        switch model.state {
        case .loaded, .empty, .loading, .idle:
            return false
        case .permissionMissing, .unsupportedSchema, .providerUnavailable, .failed:
            return true
        }
    }

    /// Horizontal room the window's traffic lights need when the sidebar is
    /// collapsed, so the tab strip's first chip clears them.
    private static let trafficLightInset: CGFloat = 76

    private func detail(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            // The strip only appears with 2+ open tabs, and never in the narrow
            // single-column layout (no room, and its own back button already owns
            // the top band). Inset past the traffic lights when the sidebar is
            // collapsed and they float over this pane's top-left.
            if !isCompact, model.openTabs.count >= 2 {
                TabStripView(
                    model: model,
                    leadingInset: model.isSidebarVisible ? 0 : Self.trafficLightInset
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            detailContent(isCompact: isCompact)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Rice.base)
            .animation(.easeOut(duration: 0.16), value: model.openTabs.count >= 2)
            .overlay(alignment: .topLeading) {
                // Compact detail carries its own in-header back button, so the
                // floating toggle is only for the regular collapsed pane.
                if !isCompact, !model.isSidebarVisible {
                    Button(action: model.toggleSidebar) {
                        Image(systemName: "sidebar.left")
                    }
                    .buttonStyle(RiceIconButtonStyle())
                    .help("Show sidebar (⌘⌃S)")
                    // Sits in the top bar under the traffic lights, its
                    // glyph lined up with the leftmost dot's left edge so
                    // the two share a left margin.
                    .padding(.leading, 6)
                    .padding(.top, 30)
                }
            }
    }

    @ViewBuilder
    private func detailContent(isCompact: Bool) -> some View {
        switch model.state {
        case .permissionMissing:
            ProviderRecoveryView(
                title: "Messages Access Needed",
                message: "Native Messages cannot read the Messages database. Allow Full Disk Access in System Settings, return here, and recheck.",
                primaryTitle: "Open Full Disk Access",
                primaryAction: model.openFullDiskAccessSettings,
                retry: model.load
            )
        case .unsupportedSchema:
            ProviderRecoveryView(
                title: "Unsupported Messages Database",
                message: "The database was opened read-only, but its required chat and message schema was not recognized.",
                primaryTitle: nil,
                primaryAction: nil,
                retry: model.load
            )
        case .providerUnavailable:
            ProviderRecoveryView(
                title: "Live Provider Safety-gated",
                message: model.health.messagesDatabase.recoverySuggestion
                    ?? "The selected live provider is not available in this build.",
                primaryTitle: nil,
                primaryAction: nil,
                retry: model.load
            )
        case .failed:
            ProviderRecoveryView(
                title: "Couldn’t Load Messages",
                message: model.errorSummary ?? "The provider reported an unexpected failure.",
                primaryTitle: nil,
                primaryAction: nil,
                retry: model.load
            )
        case .empty:
            EmptyStateView(
                icon: "tray",
                title: "No Conversations",
                message: "There is nothing to display for this provider."
            )
        case .idle, .loading:
            LoadingStateView(label: "Preparing inbox…")
        case .loaded:
            if model.selectedConversationID == nil {
                EmptyStateView(
                    icon: "bubble.left",
                    title: "No Conversation Selected",
                    message: "Choose a conversation from the sidebar, or press ⌘K for the command palette."
                )
            } else {
                ConversationView(
                    model: model.conversationModel,
                    composer: model.composerModel,
                    density: density,
                    isSidebarCollapsed: isCompact || !model.isSidebarVisible,
                    isPinned: model.selectedConversationID.map { model.pinnedIDs.contains($0) } ?? false,
                    onTogglePin: model.toggleSelectedPin,
                    isVIP: model.selectedConversationID.map { model.isVIP($0) } ?? false,
                    onToggleVIP: model.toggleSelectedVIP,
                    savedMessageIDs: model.savedMessageIDs,
                    onToggleSaved: model.toggleSaved,
                    isCompact: isCompact,
                    onBack: { model.select(nil) }
                )
                .environment(\.linkPreviewLoader, model.linkPreviewLoader)
            }
        }
    }
}

struct LoadingStateView: View {
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .riceFont(12)
                .foregroundStyle(Rice.subtext0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sidebar resize handle

/// A thin draggable strip that sits where the sidebar divider would be.
/// Shows the divider line but claims a wider hit area and a resize cursor.
private struct SidebarResizeHandle: View {
    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
            RiceDivider(axis: .vertical)
        }
        .frame(width: 8)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @ObservedObject var model: InboxModel
    let density: DisplayDensity
    /// In the single-column layout the sidebar *is* the whole window, so the
    /// "hide sidebar" toggle has nothing to reveal and is dropped.
    var isCompact = false
    @State private var isHealthPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.state == .loaded {
                folderSection
                RiceDivider()
            }
            content
            RiceDivider()
            footer
        }
        .background(Rice.mantle)
    }

    // MARK: - Folder section

    /// Selectable folder scope: All Messages + each folder + a New Folder row.
    /// Picking one narrows the conversation list (composes with the unread /
    /// needs-reply filters). Right-click a folder to rename, recolor, or delete.
    private var folderSection: some View {
        VStack(spacing: 1) {
            FolderChipRow(
                title: "All Messages",
                colorName: nil,
                count: model.conversations.count,
                isSelected: model.selectedFolderID == nil && !model.showingArchived
            ) { model.selectFolder(nil) }

            // Only surfaced once something's been archived — no empty scope to
            // wander into otherwise.
            if !model.archivedIDs.isEmpty {
                FolderChipRow(
                    title: "Archived",
                    colorName: nil,
                    systemImage: "archivebox",
                    count: model.archivedIDs.count,
                    isSelected: model.showingArchived
                ) { model.showArchived(true) }
            }

            ForEach(model.folders) { folder in
                FolderChipRow(
                    title: folder.name,
                    colorName: folder.colorName,
                    count: model.memberCount(of: folder.id),
                    isSelected: model.selectedFolderID == folder.id
                ) { model.selectFolder(folder.id) }
                .contextMenu {
                    Button("Rename / Recolor…") { model.folderEditor = .edit(folder) }
                    Button("Delete Folder", role: .destructive) { model.deleteFolder(folder.id) }
                }
            }

            Button { model.folderEditor = .create(seed: nil) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                        .frame(width: 8)
                    Text("New Folder")
                        .riceFont(12, .medium)
                        .foregroundStyle(Rice.subtext0)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// The title never truncates; icons fold into a "⋯" menu as space runs out.
    /// ViewThatFits measures the *rendered* sizes and takes the richest row that
    /// fits, so this self-corrects at every window width and zoom level — no
    /// magic pixel thresholds. The collapse is graduated (filter+reload → search
    /// → hide), with New message the last icon standing.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 36)   // traffic-light clearance
            ViewThatFits(in: .horizontal) {
                headerRow(level: 0)
                headerRow(level: 1)
                headerRow(level: 2)
                headerRow(level: 3)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .accessibilityLabel("Conversations header")
    }

    /// Progressive collapse. Higher level = fewer inline icons, more in the menu:
    /// - 0: compose · filters · reload · search · hide
    /// - 1: compose · search · hide             · ⋯(filters, reload)
    /// - 2: compose · hide                      · ⋯(search, filters, reload)
    /// - 3: compose                             · ⋯(search, filters, reload, hide)
    private func headerRow(level: Int) -> some View {
        HStack(spacing: 4) {
            Text("Messages")
                .riceSectionHeader()
                .fixedSize()   // hold full width: the title is never sacrificed
            Spacer(minLength: 8)
            composeButton
            if level == 0 {
                unreadFilterButton
                needsReplyFilterButton
                // Only surfaced when drafts exist — no drafts, no button.
                if model.hasDrafts { draftsFilterButton }
                serviceFilterMenu
                reloadButton
            }
            if level <= 1 { searchButton }
            if !isCompact, level <= 2 { hideSidebarButton }
            if level >= 1 {
                overflowMenu(includesSearch: level >= 2,
                             includesHide: !isCompact && level >= 3)
            }
        }
    }

    private var composeButton: some View {
        Button {
            model.isComposePresented = true
        } label: {
            Image(systemName: "square.and.pencil")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("New message (⌘N)")
    }

    private var unreadFilterButton: some View {
        Button {
            model.showsUnreadOnly.toggle()
        } label: {
            Image(systemName: model.showsUnreadOnly
                  ? "line.3.horizontal.decrease.circle.fill"
                  : "line.3.horizontal.decrease.circle")
        }
        .buttonStyle(RiceIconButtonStyle(isActive: model.showsUnreadOnly))
        .help(model.showsUnreadOnly ? "Show all conversations (⇧⌘U)" : "Show unread only (⇧⌘U)")
    }

    private var needsReplyFilterButton: some View {
        Button {
            model.showsNeedsReplyOnly.toggle()
        } label: {
            Image(systemName: model.showsNeedsReplyOnly
                  ? "arrowshape.turn.up.left.circle.fill"
                  : "arrowshape.turn.up.left.circle")
        }
        .buttonStyle(RiceIconButtonStyle(isActive: model.showsNeedsReplyOnly))
        .help(model.showsNeedsReplyOnly ? "Show all conversations (⇧⌘R)" : "Needs reply only (⇧⌘R)")
    }

    private var draftsFilterButton: some View {
        Button {
            model.showsDraftsOnly.toggle()
        } label: {
            Image(systemName: model.showsDraftsOnly
                  ? "pencil.circle.fill"
                  : "pencil.circle")
        }
        .buttonStyle(RiceIconButtonStyle(isActive: model.showsDraftsOnly))
        .help(model.showsDraftsOnly ? "Show all conversations (⇧⌘D)" : "Drafts only (⇧⌘D)")
    }

    /// Multi-select service visibility. Unlike the unread / needs-reply filters
    /// this is a *composable* axis, so it's a checkmark menu rather than a single
    /// toggle button. A distinct bubble icon (not the funnel the unread filter
    /// uses) fills and tints with the accent when anything is hidden, so the
    /// header reads at a glance whether a service filter is on. Sizing mirrors
    /// `RiceIconButtonStyle` so it sits flush with its neighbours.
    private var serviceFilterMenu: some View {
        let active = !model.hiddenServices.isEmpty
        // Drive the Menu through the *same* RiceIconButtonStyle the sibling icons
        // use (via `.menuStyle(.button)`), so it's pixel-identical in size and
        // shares their neutral→accent active treatment. `isActive` keys off the
        // hidden set alone: all services shown ⇒ neutral grey, like the others.
        return Menu {
            serviceMenuContent
        } label: {
            Image(systemName: "message")
        }
        .menuStyle(.button)
        .buttonStyle(RiceIconButtonStyle(isActive: active))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(active ? "Service filter on — some services hidden" : "Filter by service")
    }

    /// The per-service toggles plus a reset, shared by the inline menu and the
    /// overflow menu so both stay in lockstep. Native `Toggle`s render as
    /// checkmark rows, so a checked service = shown; toggling the same row again
    /// flips it back. "Show All Services" is the explicit off switch — disabled
    /// (and thus a state indicator) whenever nothing is hidden.
    @ViewBuilder
    private var serviceMenuContent: some View {
        Section("Show Services") {
            ForEach(MessageServiceKind.togglable, id: \.self) { service in
                Toggle(service.displayLabel, isOn: Binding(
                    get: { model.showsService(service) },
                    set: { _ in model.toggleService(service) }
                ))
            }
        }
        Divider()
        Button("Show All Services") { model.showAllServices() }
            .disabled(model.hiddenServices.isEmpty)
    }

    private var reloadButton: some View {
        Button(action: model.load) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Reload (⌘R)")
    }

    private var searchButton: some View {
        Button {
            model.isSearchPresented = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Search messages (⇧⌘F)")
    }

    private var hideSidebarButton: some View {
        Button(action: model.toggleSidebar) {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Hide sidebar (⌘⌃S)")
    }

    /// The actions that don't fit inline, tucked under a "⋯" button. Which ones
    /// spill in depends on how far the row had to collapse.
    private func overflowMenu(includesSearch: Bool, includesHide: Bool) -> some View {
        Menu {
            if includesSearch {
                Button {
                    model.isSearchPresented = true
                } label: {
                    Label("Search Messages", systemImage: "magnifyingglass")
                }
            }
            Button {
                model.showsUnreadOnly.toggle()
            } label: {
                Label(model.showsUnreadOnly ? "Show All Conversations" : "Show Unread Only",
                      systemImage: model.showsUnreadOnly
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
            }
            Button {
                model.showsNeedsReplyOnly.toggle()
            } label: {
                Label(model.showsNeedsReplyOnly ? "Show All Conversations" : "Show Needs Reply",
                      systemImage: model.showsNeedsReplyOnly
                      ? "arrowshape.turn.up.left.circle.fill"
                      : "arrowshape.turn.up.left.circle")
            }
            if model.hasDrafts {
                Button {
                    model.showsDraftsOnly.toggle()
                } label: {
                    Label(model.showsDraftsOnly ? "Show All Conversations" : "Show Drafts",
                          systemImage: model.showsDraftsOnly
                          ? "pencil.circle.fill"
                          : "pencil.circle")
                }
            }
            Menu {
                serviceMenuContent
            } label: {
                Label(model.hiddenServices.isEmpty ? "Filter by Service" : "Filter by Service — Some Hidden",
                      systemImage: "message")
            }
            Button {
                model.load()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            if includesHide {
                Button {
                    model.toggleSidebar()
                } label: {
                    Label("Hide Sidebar", systemImage: "sidebar.left")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .riceFont(13)
                .foregroundStyle(Rice.subtext1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading, .idle:
            LoadingStateView(label: "Loading conversations…")
        case .empty:
            EmptyStateView(
                icon: "bubble.left.and.bubble.right",
                title: "No Conversations",
                message: "This provider returned no conversations."
            )
        case .loaded:
            if model.visibleConversations.isEmpty,
               model.filter != .all || model.selectedFolderID != nil || model.showingArchived {
                emptyScopeState
            } else {
                conversationList
            }
        case .permissionMissing, .unsupportedSchema, .providerUnavailable, .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .riceFont(22)
                    .foregroundStyle(Rice.yellow)
                Text("Provider unavailable")
                    .riceFont(13, .semibold)
                    .foregroundStyle(Rice.subtext1)
                Button("Recheck", action: model.load)
                    .buttonStyle(RiceSubtleButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Shown when the active folder scope and/or filter leaves nothing to list.
    /// The reset clears both axes so the user always lands back on everything.
    private var emptyScopeState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .riceFont(22)
                .foregroundStyle(Rice.green)
            Text(emptyScopeMessage)
                .riceFont(12, .medium)
                .foregroundStyle(Rice.subtext1)
            Button("Show All Messages") {
                model.filter = .all
                model.selectFolder(nil)
            }
            .buttonStyle(RiceSubtleButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyScopeMessage: String {
        if model.showingArchived { return "No archived conversations" }
        switch model.filter {
        case .needsReply: return "Nothing awaiting a reply"
        case .unread: return "No unread conversations"
        case .drafts: return "No drafts"
        case .all: return "No conversations in this folder"
        }
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                // VIPs get their own titled section above the rest, but only in
                // the unscoped "All Messages" view — inside a folder the list is
                // already a single scoped slice (see `model.showsVIPSection`).
                if model.showsVIPSection {
                    listSectionHeader("VIP", systemImage: "star.fill")
                    ForEach(model.visibleVIPConversations) { conversation in
                        conversationRow(conversation)
                    }
                    // Skip the "All" divider when every visible thread is a VIP.
                    if !model.visibleNonVIPConversations.isEmpty {
                        listSectionHeader("All", systemImage: "tray.full")
                    }
                }
                ForEach(model.visibleNonVIPConversations) { conversation in
                    conversationRow(conversation)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .accessibilityLabel("Conversations")
    }

    /// Snooze presets for a thread, plus an Unsnooze row when one is active.
    @ViewBuilder
    private func snoozeMenu(for id: ConversationID) -> some View {
        Menu("Snooze") {
            ForEach(SnoozeOption.allCases) { option in
                Button {
                    model.snooze(id, option: option)
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
            }
            if model.isSnoozed(id) {
                Divider()
                Button("Unsnooze") { model.unsnooze(id) }
            }
        }
    }

    /// A subtle small-caps divider between the VIP and All groups.
    private func listSectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .riceFont(8)
            Text(title)
                .riceSectionHeader()
            Spacer(minLength: 0)
        }
        .foregroundStyle(Rice.subtext0)
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .padding(.bottom, 1)
    }

    private func conversationRow(_ conversation: Conversation) -> some View {
        ConversationRowButton(
            conversation: conversation,
            isPinned: model.pinnedIDs.contains(conversation.id),
            isVIP: model.isVIP(conversation.id),
            isMuted: model.isMuted(conversation.id),
            isSelected: model.selectedConversationID == conversation.id,
            showsUnread: model.hasVisibleUnread(conversation),
            density: density,
            onOpenInNewTab: { model.openInNewTab(conversation.id) }
        ) {
            model.select(conversation.id)
        }
        .contextMenu {
            Button("Open in New Tab") { model.openInNewTab(conversation.id) }
            Divider()
            Button(model.isVIP(conversation.id) ? "Remove from VIP" : "Add to VIP") {
                model.toggleVIP(conversation.id)
            }
            Button(model.pinnedIDs.contains(conversation.id) ? "Unpin" : "Pin") {
                model.togglePin(conversation.id)
            }
            Menu("Folders") {
                let containing = model.folders(containing: conversation.id)
                ForEach(model.folders) { folder in
                    Button {
                        model.toggleMembership(conversation.id, inFolder: folder.id)
                    } label: {
                        // SwiftUI renders the checkmark only when the
                        // Label's image is a checkmark; plain Text for
                        // non-members keeps the rows aligned.
                        if containing.contains(folder.id) {
                            Label(folder.name, systemImage: "checkmark")
                        } else {
                            Text(folder.name)
                        }
                    }
                }
                if !model.folders.isEmpty { Divider() }
                Button("New Folder…") { model.folderEditor = .create(seed: conversation.id) }
            }
            Divider()
            snoozeMenu(for: conversation.id)
            Button(model.isMuted(conversation.id) ? "Unmute" : "Mute") {
                model.toggleMuted(conversation.id)
            }
            Button(model.isArchived(conversation.id) ? "Unarchive" : "Archive") {
                model.toggleArchived(conversation.id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(ProviderMode.allCases) { mode in
                    Button(mode.title) { model.switchProvider(to: mode) }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(healthColor)
                        .frame(width: 6, height: 6)
                    Text(model.providerMode.title)
                        .riceFont(11, .medium)
                        .foregroundStyle(Rice.subtext1)
                    Image(systemName: "chevron.up.chevron.down")
                        .riceFont(8)
                        .foregroundStyle(Rice.overlay0)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Messages provider")

            Spacer()

            Button {
                isHealthPresented.toggle()
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(RiceIconButtonStyle())
            .help("Provider health")
            .popover(isPresented: $isHealthPresented, arrowEdge: .top) {
                ProviderHealthView(health: model.health, recheck: model.load)
                    .frame(width: 320)
                    .padding(16)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var healthColor: Color {
        switch model.health.messagesDatabase.availability {
        case .available: Rice.green
        case .limited, .unknown: Rice.yellow
        case .unavailable: Rice.red
        }
    }
}

private struct ConversationRowButton: View {
    let conversation: Conversation
    let isPinned: Bool
    var isVIP: Bool = false
    let isMuted: Bool
    let isSelected: Bool
    let showsUnread: Bool
    let density: DisplayDensity
    /// ⌘-click opens the thread in a new tab instead of navigating in place.
    var onOpenInNewTab: () -> Void = {}
    let action: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var isHovering = false

    var body: some View {
        Button {
            if NSEvent.modifierFlags.contains(.command) { onOpenInNewTab() } else { action() }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                AvatarView(conversation: conversation)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        // A VIP is implicitly pinned, so its star stands in for
                        // the pin badge rather than doubling up.
                        if isVIP {
                            Image(systemName: "star.fill")
                                .riceFont(8)
                                .foregroundStyle(Rice.yellow)
                                .accessibilityLabel("VIP")
                        } else if isPinned {
                            Image(systemName: "pin.fill")
                                .riceFont(8)
                                .foregroundStyle(Rice.overlay0)
                                .accessibilityLabel("Pinned")
                        }
                        if isMuted {
                            Image(systemName: "bell.slash.fill")
                                .riceFont(8)
                                .foregroundStyle(Rice.overlay0)
                                .accessibilityLabel("Muted")
                        }
                        Text(conversation.displayName)
                            .riceFont(13, hasUnread ? .semibold : .medium)
                            .foregroundStyle(Rice.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(CompactTime.string(from: conversation.lastActivity))
                            .riceFont(10)
                            .foregroundStyle(Rice.overlay0)
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text(conversation.lastMessagePreview)
                            .riceFont(11)
                            .foregroundStyle(Rice.subtext0)
                            .lineLimit(2, reservesSpace: true)
                            .privacyBlurred(revealed: isHovering)
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 3) {
                            ServiceChip(service: conversation.service)
                            if showsUnread, let count = conversation.unreadCount, count > 0 {
                                Text("\(count)")
                                    .riceFont(9, .bold)
                                    .foregroundStyle(Rice.crust)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(accent, in: Capsule())
                                    .accessibilityLabel("\(count) unread messages")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, density.rowVerticalPadding)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(conversation.displayName), \(conversation.service.displayLabel)")
    }

    private var hasUnread: Bool {
        showsUnread && (conversation.unreadCount ?? 0) > 0
    }

    private var rowBackground: Color {
        if isSelected { return accent.opacity(0.18) }
        if isHovering { return Rice.surface0.opacity(0.55) }
        return .clear
    }
}

// MARK: - Folders

/// One selectable row in the sidebar's folder scope list. `colorName == nil`
/// marks the "All Messages" row (a tray glyph instead of a color dot).
private struct FolderChipRow: View {
    let title: String
    let colorName: String?
    /// Glyph shown when `colorName == nil` (the non-folder scope rows). Folders
    /// use their color dot instead.
    var systemImage: String = "tray.full"
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                marker
                Text(title)
                    .riceFont(12, .medium)
                    .foregroundStyle(Rice.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .riceFont(10)
                    .foregroundStyle(Rice.overlay0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(rowBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(title), \(count) conversations")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var marker: some View {
        if let colorName {
            Circle()
                .fill(Rice.accent(named: colorName))
                .frame(width: 8, height: 8)
        } else {
            Image(systemName: systemImage)
                .riceFont(9)
                .foregroundStyle(Rice.subtext0)
                .frame(width: 8)
        }
    }

    private var rowBackground: Color {
        if isSelected { return accent.opacity(0.18) }
        if isHovering { return Rice.surface0.opacity(0.55) }
        return .clear
    }
}

/// Whether the folder editor is creating a new folder (optionally seeding a
/// conversation into it) or editing an existing one. `Identifiable` so it drives
/// a `.sheet(item:)`.
enum FolderEditorMode: Identifiable {
    case create(seed: ConversationID?)
    case edit(Folder)

    var id: String {
        switch self {
        case .create: "create"
        case let .edit(folder): "edit-\(folder.id)"
        }
    }
}

/// Create / rename / recolor a folder. Reuses the accent swatch row from
/// Settings so folder colors match the app's Rice palette.
private struct FolderEditorView: View {
    @ObservedObject var model: InboxModel
    let mode: FolderEditorMode
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorName: String
    @FocusState private var isNameFocused: Bool

    init(model: InboxModel, mode: FolderEditorMode) {
        self.model = model
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _colorName = State(initialValue: Rice.accentNames.first ?? "mauve")
        case let .edit(folder):
            _name = State(initialValue: folder.name)
            _colorName = State(initialValue: folder.colorName)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit Folder" : "New Folder")
                .riceFont(15, .semibold)
                .foregroundStyle(Rice.text)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .riceSectionHeader()
                TextField("Folder name", text: $name)
                    .textFieldStyle(.plain)
                    .riceFont(13)
                    .foregroundStyle(Rice.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Rice.surface0, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .focused($isNameFocused)
                    .onSubmit(commit)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .riceSectionHeader()
                HStack(spacing: 8) {
                    ForEach(Rice.accentNames, id: \.self) { swatch in
                        Button {
                            colorName = swatch
                        } label: {
                            Circle()
                                .fill(Rice.accent(named: swatch))
                                .frame(width: 18, height: 18)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Rice.text, lineWidth: colorName == swatch ? 2 : 0)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(swatch) color")
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(RiceSubtleButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Create", action: commit)
                    .buttonStyle(RiceProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(Rice.mantle)
        .onAppear { isNameFocused = true }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case let .create(seed):
            model.createFolder(name: trimmedName, colorName: colorName, seedConversation: seed)
        case let .edit(folder):
            model.updateFolder(folder.id, name: trimmedName, colorName: colorName)
        }
        dismiss()
    }
}

// MARK: - Recovery & health

private struct ProviderRecoveryView: View {
    let title: String
    let message: String
    let primaryTitle: String?
    let primaryAction: (() -> Void)?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .riceFont(34, .light)
                .foregroundStyle(Rice.surface2)
            Text(title)
                .riceFont(17, .semibold)
                .foregroundStyle(Rice.text)
            Text(message)
                .riceFont(12)
                .foregroundStyle(Rice.subtext0)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 8) {
                if let primaryTitle, let primaryAction {
                    Button(primaryTitle, action: primaryAction)
                        .buttonStyle(RiceProminentButtonStyle())
                }
                Button("Recheck", action: retry)
                    .buttonStyle(RiceSubtleButtonStyle())
            }
            Text("System Integrity Protection stays enabled. Native Messages never modifies Apple’s Messages database.")
                .riceFont(10)
                .foregroundStyle(Rice.overlay0)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct ProviderHealthView: View {
    let health: ProviderHealth
    let recheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Provider Health")
                .riceSectionHeader()
            HealthRow(title: "Messages database", state: health.messagesDatabase)
            HealthRow(title: "Live events", state: health.liveEvents)
            HealthRow(title: "Sending", state: health.sending)
            HealthRow(title: "Contacts", state: health.contacts)
            HealthRow(title: "Notifications", state: health.notifications)
            RiceDivider()
            HStack(spacing: 8) {
                Button("Recheck", action: recheck)
                    .buttonStyle(RiceSubtleButtonStyle())
                if health.contacts.reason == .permissionMissing {
                    Button("Open Contacts Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(RiceSubtleButtonStyle())
                }
            }
        }
    }
}

private struct HealthRow: View {
    let title: String
    let state: HealthState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .riceFont(12, .medium)
                    .foregroundStyle(Rice.text)
                Text(state.reason.displayLabel)
                    .riceFont(10)
                    .foregroundStyle(Rice.subtext0)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch state.availability {
        case .available: Rice.green
        case .limited, .unknown: Rice.yellow
        case .unavailable: Rice.red
        }
    }
}

private extension HealthReason {
    var displayLabel: String {
        switch self {
        case .ready: "Ready"
        case .fixtureMode: "Fixture mode"
        case .permissionMissing: "Permission missing"
        case .databaseMissing: "Database missing"
        case .unsupportedSchema: "Unsupported schema"
        case .providerFailure: "Provider failure"
        case .reconnecting: "Reconnecting"
        case .disabled: "Disabled"
        case .notRequested: "Not requested"
        case .manualVerificationRequired: "Manual verification required"
        }
    }
}
