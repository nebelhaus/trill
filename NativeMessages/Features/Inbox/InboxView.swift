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

    var body: some View {
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

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Rice.base)
                .overlay(alignment: .topLeading) {
                    if !model.isSidebarVisible {
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
        .background(Rice.mantle)
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.16), value: model.isSidebarVisible)
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
        .sheet(isPresented: $model.isComposePresented) {
            ComposeSheet(model: model)
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

    @ViewBuilder
    private var detail: some View {
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
                    isSidebarCollapsed: !model.isSidebarVisible,
                    isPinned: model.selectedConversationID.map { model.pinnedIDs.contains($0) } ?? false,
                    onTogglePin: model.toggleSelectedPin
                )
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
    @State private var isHealthPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            RiceDivider()
            footer
        }
        .background(Rice.mantle)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 36)   // traffic-light clearance
            HStack(spacing: 4) {
                Text("Messages")
                    .riceSectionHeader()
                Spacer()
                Button {
                    model.isComposePresented = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("New message (⌘N)")
                Button {
                    model.showsUnreadOnly.toggle()
                } label: {
                    Image(systemName: model.showsUnreadOnly
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(RiceIconButtonStyle(isActive: model.showsUnreadOnly))
                .help(model.showsUnreadOnly ? "Show all conversations (⇧⌘U)" : "Show unread only (⇧⌘U)")
                Button(action: model.load) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("Reload (⌘R)")
                Button {
                    model.isSearchPresented = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("Search messages (⇧⌘F)")
                Button(action: model.toggleSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("Hide sidebar (⌘⌃S)")
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .accessibilityLabel("Conversations header")
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
            if model.visibleConversations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .riceFont(22)
                        .foregroundStyle(Rice.green)
                    Text("No unread conversations")
                        .riceFont(12, .medium)
                        .foregroundStyle(Rice.subtext1)
                    Button("Show All") { model.showsUnreadOnly = false }
                        .buttonStyle(RiceSubtleButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(model.visibleConversations) { conversation in
                    ConversationRowButton(
                        conversation: conversation,
                        isPinned: model.pinnedIDs.contains(conversation.id),
                        isSelected: model.selectedConversationID == conversation.id,
                        showsUnread: model.hasVisibleUnread(conversation),
                        density: density
                    ) {
                        model.select(conversation.id)
                    }
                    .contextMenu {
                        Button(model.pinnedIDs.contains(conversation.id) ? "Unpin" : "Pin") {
                            model.togglePin(conversation.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .accessibilityLabel("Conversations")
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
    let isSelected: Bool
    let showsUnread: Bool
    let density: DisplayDensity
    let action: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                AvatarView(conversation: conversation)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        if isPinned {
                            Image(systemName: "pin.fill")
                                .riceFont(8)
                                .foregroundStyle(Rice.overlay0)
                                .accessibilityLabel("Pinned")
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
