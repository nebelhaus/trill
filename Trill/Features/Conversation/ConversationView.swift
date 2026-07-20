import AppKit
import SwiftUI

/// A sendable tapback offered in the message context menu: the domain reaction
/// kind plus its glyph and label. `sendable` is the six standard iMessage
/// tapbacks in Messages.app order — the only kinds the write backend can issue
/// (`.custom` emoji reactions aren't wired yet). Kept `internal` (not nested in a
/// private view) so the vetting tests can assert it never drifts from
/// `PlatformWriteBackend.reactionKey`.
struct Tapback: Equatable {
    let kind: ReactionKind
    let glyph: String
    let label: String

    static let sendable: [Tapback] = [
        Tapback(kind: .love, glyph: "❤️", label: "Love"),
        Tapback(kind: .like, glyph: "👍", label: "Like"),
        Tapback(kind: .dislike, glyph: "👎", label: "Dislike"),
        Tapback(kind: .laugh, glyph: "😂", label: "Laugh"),
        Tapback(kind: .emphasis, glyph: "‼️", label: "Emphasize"),
        Tapback(kind: .question, glyph: "❓", label: "Question"),
    ]
}

struct ConversationView: View {
    @ObservedObject var model: ConversationModel
    @ObservedObject var composer: ComposerModel
    var density: DisplayDensity = .comfortable
    /// When the sidebar is hidden the toggle + traffic lights own the header's
    /// top-left corner, so the title is centered in the bar (Messages-style)
    /// instead of being shoved right into an awkward gap.
    var isSidebarCollapsed = false
    var isPinned = false
    var onTogglePin: () -> Void = {}
    var isVIP = false
    var onToggleVIP: () -> Void = {}
    /// Bookmarked message IDs and the per-message toggle, threaded down to each
    /// bubble for the star glyph + Save context action. Owned by `InboxModel`.
    var savedMessageIDs: Set<MessageID> = []
    var onToggleSaved: (MessageID) -> Void = { _ in }
    /// Whether tapbacks can be sent (provider capability + Accessibility health).
    /// Off → the per-message "React" submenu is absent, so the feature stays
    /// invisible everywhere the write overlay isn't active. Owned by `InboxModel`.
    var canReact = false
    var onReact: (MessageID, ReactionKind) -> Void = { _, _ in }
    /// Single-column layout: the header grows a leading back button that pops
    /// to the conversation list, mobile-nav-bar style.
    var isCompact = false
    var onBack: () -> Void = {}

    @State private var isGalleryPresented = false
    @State private var isStatsPresented = false
    @State private var isStylePresented = false
    @State private var isExportPresented = false
    @State private var isSelectionExportPresented = false
    /// Live height of the whole thread pane; the composer caps its growth at half.
    @State private var paneHeight: CGFloat = 0
    /// Measured width of the trailing action group in the centered (sidebar-hidden)
    /// header. Drives the symmetric title reserve so the count of icons and the
    /// zoom level can't push them under the centered name.
    @State private var headerActionsWidth: CGFloat = Self.centeredReserve

    /// Fallback reserve for the centered (sidebar-hidden) header before the
    /// trailing actions have been measured.
    private static let centeredReserve: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            if model.isSelecting {
                selectionBar
            } else if isCompact {
                compactHeader
            } else {
                header
            }
            RiceDivider()
            if model.isFindPresented {
                FindBar(model: model)
                RiceDivider()
            }
            MessageTimelineView(
                model: model,
                density: density,
                savedMessageIDs: savedMessageIDs,
                onToggleSaved: onToggleSaved,
                canReact: canReact,
                onReact: onReact
            )
            RiceDivider()
            ComposerView(model: composer, maxHeight: paneHeight * 0.5)
        }
        .animation(.easeOut(duration: 0.14), value: model.isFindPresented)
        .background(Rice.base)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, height in paneHeight = height }
            }
        )
        .dropDestination(for: URL.self) { urls, _ in
            composer.stageAttachments(urls)
            return composer.canSendAttachments
        }
        .sheet(isPresented: $isGalleryPresented) {
            MediaGalleryView(
                model: model,
                onReveal: { target in
                    isGalleryPresented = false
                    model.reveal(target)
                },
                onClose: { isGalleryPresented = false }
            )
        }
        .sheet(isPresented: $isStatsPresented) {
            ConversationStatsView(model: model, onClose: { isStatsPresented = false })
        }
        .sheet(isPresented: $isStylePresented) {
            StyleProfileView(
                scope: .conversation(model.conversation?.displayName ?? "Conversation"),
                load: { await model.loadAllForExport() },
                onClose: { isStylePresented = false }
            )
        }
        .sheet(isPresented: $isExportPresented) {
            ConversationExportView(model: model, onClose: { isExportPresented = false })
        }
        .sheet(isPresented: $isSelectionExportPresented) {
            ConversationExportView(
                model: model,
                presetMessages: model.selectedMessages,
                onClose: { isSelectionExportPresented = false }
            )
        }
        .animation(.easeOut(duration: 0.14), value: model.isSelecting)
    }

    /// Media + stats, shared by the regular and compact headers so both stay in
    /// sync as thread-level actions are added.
    @ViewBuilder
    private var threadActionButtons: some View {
        Button {
            model.beginJumpToDate()
        } label: {
            Image(systemName: "calendar")
        }
        .buttonStyle(RiceIconButtonStyle(isActive: model.isJumpToDatePresented))
        .help("Jump to date (⌘J)")
        .disabled(model.conversation == nil)
        .popover(isPresented: $model.isJumpToDatePresented, arrowEdge: .bottom) {
            JumpToDatePopover(
                initialDate: model.messages.last?.createdAt ?? model.conversation?.lastActivity ?? Date(),
                onJump: { model.jump(to: $0) }
            )
        }
        Button {
            isStatsPresented = true
        } label: {
            Image(systemName: "chart.bar")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Conversation stats")
        Button {
            isStylePresented = true
        } label: {
            Image(systemName: "signature")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Export writing-style profile")
        Button {
            isGalleryPresented = true
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Media gallery")
        Button {
            model.beginSelection()
        } label: {
            Image(systemName: "checkmark.circle")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Select messages to export")
        .disabled(model.state != .loaded)
        Button {
            isExportPresented = true
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(RiceIconButtonStyle())
        .help("Export whole conversation")
    }

    /// Header replacement while multi-selecting: a live count on the left and,
    /// on the right, select-all plus the prominent Export CTA that is the whole
    /// point of this mode. Mirrors the compact header's traffic-light clearance
    /// so it sits correctly in the single-column layout too.
    private var selectionBar: some View {
        VStack(spacing: 0) {
            if isCompact { Color.clear.frame(height: 22) }
            HStack(spacing: 10) {
                Button(action: model.endSelection) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("Cancel selection")

                Text(selectionCountLabel)
                    .riceFont(14, .semibold)
                    .foregroundStyle(Rice.text)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Button(selectAllTitle) {
                    model.toggleSelectAll()
                }
                .buttonStyle(RiceSubtleButtonStyle())
                .disabled(model.messages.isEmpty)

                Button {
                    isSelectionExportPresented = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(RiceProminentButtonStyle())
                .disabled(model.selectedMessageIDs.isEmpty)
            }
            .padding(.leading, selectionBarLeadingInset)
            .padding(.trailing, 16)
            .padding(.top, isCompact ? 0 : 12)
            .padding(.bottom, 9)
        }
    }

    /// Clear the window's traffic lights when the sidebar is hidden at the
    /// regular breakpoint; the compact bar clears them with a top spacer instead.
    private var selectionBarLeadingInset: CGFloat {
        if isCompact { return 12 }
        return isSidebarCollapsed ? 78 : 16
    }

    private var selectionCountLabel: String {
        let count = model.selectedMessageIDs.count
        return count == 0 ? "Select messages" : "\(count) selected"
    }

    private var selectAllTitle: String {
        let all = !model.messages.isEmpty && model.selectedMessageIDs.count == model.messages.count
        return all ? "Deselect All" : "Select All"
    }

    private var header: some View {
        Group {
            if isSidebarCollapsed {
                // Sidebar hidden: center the title in the bar (Messages-style).
                // Only reachable at the regular breakpoint (≥ 620pt) where the
                // full-width thread pane always has room for the chip.
                ZStack {
                    titleBlock
                        .frame(maxWidth: .infinity, alignment: .center)
                        // Reserve the real icon-group width on both sides so the
                        // centered name truncates instead of sliding under the
                        // actions — robust to icon count and zoom level.
                        .padding(.horizontal, headerActionsWidth + 12)
                    HStack(spacing: 10) {
                        Spacer()
                        headerActions(showsChip: true)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: HeaderActionsWidthKey.self,
                                        value: proxy.size.width
                                    )
                                }
                            )
                    }
                }
                .onPreferenceChange(HeaderActionsWidthKey.self) { headerActionsWidth = $0 }
            } else {
                // Sidebar open: drop the service chip before the name truncates.
                // ViewThatFits measures the rendered row, so it stays correct at
                // every pane width and zoom level — no pixel thresholds.
                ViewThatFits(in: .horizontal) {
                    inlineHeaderRow(showsChip: true)
                    inlineHeaderRow(showsChip: false)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private func inlineHeaderRow(showsChip: Bool) -> some View {
        HStack(spacing: 10) {
            titleBlock
            Spacer(minLength: 8)
            headerActions(showsChip: showsChip)
        }
    }

    private var titleBlock: some View {
        HStack(spacing: 10) {
            if let conversation = model.conversation {
                AvatarView(conversation: conversation, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.conversation?.displayName ?? "Conversation")
                    .riceFont(14, .semibold)
                    .foregroundStyle(Rice.text)
                    .lineLimit(1)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                        .lineLimit(1)
                }
            }
        }
    }

    private func headerActions(showsChip: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: onToggleVIP) {
                Image(systemName: isVIP ? "star.fill" : "star")
            }
            .buttonStyle(RiceIconButtonStyle(isActive: isVIP))
            .help(isVIP ? "Remove from VIP (⌃⌘V)" : "Add to VIP (⌃⌘V)")
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(RiceIconButtonStyle())
            .help(isPinned ? "Unpin conversation (⇧⌘P)" : "Pin conversation (⇧⌘P)")
            threadActionButtons
            if showsChip, let service = model.conversation?.service {
                ServiceChip(service: service)
            }
        }
    }

    /// Single-column nav bar: [‹ Back] avatar title …… actions, all on one
    /// row sitting below the traffic lights. No centered title / fixed reserve
    /// — the title just takes the slack and truncates, so it reads well even
    /// when the window is a thin sliver.
    private var compactHeader: some View {
        VStack(spacing: 0) {
            // Clear the window's traffic lights, which float over this corner.
            Color.clear.frame(height: 22)
            HStack(spacing: 8) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("Back to conversations")

                if let conversation = model.conversation {
                    AvatarView(conversation: conversation, size: 24)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.conversation?.displayName ?? "Conversation")
                        .riceFont(14, .semibold)
                        .foregroundStyle(Rice.text)
                        .lineLimit(1)
                    if let subtitle = headerSubtitle {
                        Text(subtitle)
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext0)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Button(action: onToggleVIP) {
                    Image(systemName: isVIP ? "star.fill" : "star")
                }
                .buttonStyle(RiceIconButtonStyle(isActive: isVIP))
                .help(isVIP ? "Remove from VIP (⌃⌘V)" : "Add to VIP (⌃⌘V)")
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help(isPinned ? "Unpin conversation (⇧⌘P)" : "Pin conversation (⇧⌘P)")
                threadActionButtons
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.bottom, 9)
    }

    /// Participant summary shown under the conversation name.
    private var headerSubtitle: String? {
        guard let conversation = model.conversation else { return nil }
        if conversation.kind == .group {
            return "\(conversation.participants.count) participants"
        }
        return conversation.participants.first?.displayName
            ?? conversation.participants.first?.handle
            ?? "Direct conversation"
    }
}

private struct MessageTimelineView: View {
    @ObservedObject var model: ConversationModel
    let density: DisplayDensity
    let savedMessageIDs: Set<MessageID>
    let onToggleSaved: (MessageID) -> Void
    var canReact = false
    var onReact: (MessageID, ReactionKind) -> Void = { _, _ in }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                switch model.state {
                case .idle, .loading:
                    LoadingStateView(label: "Loading recent messages…")
                case .empty:
                    EmptyStateView(
                        icon: "text.bubble",
                        title: "No Messages",
                        message: "This conversation has no visible messages."
                    )
                case .failed:
                    EmptyStateView(
                        icon: "exclamationmark.bubble",
                        title: "Messages Unavailable",
                        message: "The provider could not load this conversation."
                    )
                case .loaded:
                    ScrollView {
                        // Eager VStack, not Lazy: a page is only ~36 rows, and
                        // LazyVStack + .defaultScrollAnchor(.bottom) leaves the
                        // viewport blank until a scroll forces row realization —
                        // the churn is worst in image-heavy threads whose async
                        // thumbnails keep resizing rows during initial layout.
                        VStack(spacing: density.timelineSpacing) {
                            if model.nextBefore != nil {
                                loadOlderButton(proxy: proxy)
                            }

                            let latestOutgoingID = model.messages.last(where: \.isOutgoing)?.id
                            let replies = repliesByOrigin
                            let findMatches = model.findMatchSet
                            let currentFindMatch = model.currentFindMatchID
                            ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                                if startsDay(at: index) {
                                    DaySeparator(date: message.createdAt)
                                }
                                MessageRow(
                                    message: message,
                                    startsGroup: startsGroup(at: index),
                                    endsGroup: endsGroup(at: index),
                                    isLatestOutgoing: message.id == latestOutgoingID,
                                    isHighlighted: message.id == model.highlightedMessageID,
                                    isFindMatch: findMatches.contains(message.id),
                                    isCurrentFindMatch: message.id == currentFindMatch,
                                    isSaved: savedMessageIDs.contains(message.id),
                                    isSelecting: model.isSelecting,
                                    isSelected: model.selectedMessageIDs.contains(message.id),
                                    replyIDs: replies[message.id] ?? [],
                                    onJump: { target in
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            proxy.scrollTo(target, anchor: .center)
                                        }
                                    },
                                    onToggleSaved: { onToggleSaved(message.id) },
                                    onToggleSelection: { model.toggleSelection(message.id) },
                                    canReact: canReact,
                                    onReact: { kind in onReact(message.id, kind) }
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .id(model.conversation?.id)
                    .onChange(of: model.revealTarget) { _, target in
                        guard let target else { return }
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(target, anchor: .center)
                        }
                        model.consumeRevealTarget()
                    }
                }
            }
        }
        .accessibilityLabel("Message timeline")
    }

    private func loadOlderButton(proxy: ScrollViewProxy) -> some View {
        Button {
            let anchor = model.messages.first?.id
            Task {
                await model.loadOlder()
                if let anchor {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        } label: {
            if model.isLoadingOlder {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Load Earlier Messages", systemImage: "arrow.up")
            }
        }
        .buttonStyle(RiceSubtleButtonStyle())
        .disabled(model.isLoadingOlder)
        .padding(.vertical, 8)
    }

    private var repliesByOrigin: [MessageID: [MessageID]] {
        var result: [MessageID: [MessageID]] = [:]
        for message in model.messages {
            if let origin = message.replyTo {
                result[origin, default: []].append(message.id)
            }
        }
        return result
    }

    private func startsDay(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            model.messages[index - 1].createdAt,
            inSameDayAs: model.messages[index].createdAt
        )
    }

    private func startsGroup(at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = model.messages[index - 1]
        let current = model.messages[index]
        return previous.isOutgoing != current.isOutgoing
            || previous.sender?.id != current.sender?.id
            || current.createdAt.timeIntervalSince(previous.createdAt) > 300
    }

    private func endsGroup(at index: Int) -> Bool {
        guard index + 1 < model.messages.count else { return true }
        return startsGroup(at: index + 1)
    }
}

/// In-thread find bar (⌘F). Browser-style: docked under the header, scoped to
/// the messages loaded in the timeline. ⏎ / ⇧⏎ (or the chevrons) step through
/// matches; esc closes.
private struct FindBar: View {
    @ObservedObject var model: ConversationModel
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .riceFont(12)
                .foregroundStyle(Rice.subtext0)
            TextField("Find in conversation", text: $model.findQuery)
                .textFieldStyle(.plain)
                .riceFont(13)
                .foregroundStyle(Rice.text)
                .focused($isFieldFocused)
                .onSubmit { model.findNext() }

            Text(matchLabel)
                .riceFont(10, .medium)
                .monospacedDigit()
                .foregroundStyle(hasNoMatches ? Rice.red : Rice.subtext0)
                .lineLimit(1)
                .fixedSize()

            RiceDivider(axis: .vertical).frame(height: 16)

            Button { model.findPrevious() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(RiceIconButtonStyle())
            .disabled(model.findMatches.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button { model.findNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(RiceIconButtonStyle())
            .disabled(model.findMatches.isEmpty)
            .help("Next match (⌘G)")

            Button { model.endFind() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(RiceIconButtonStyle())
            .help("Close find (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Rice.mantle)
        .onAppear { isFieldFocused = true }
        .onExitCommand { model.endFind() }
    }

    private var trimmedQuery: String {
        model.findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasNoMatches: Bool {
        !trimmedQuery.isEmpty && model.findMatches.isEmpty
    }

    private var matchLabel: String {
        if trimmedQuery.isEmpty { return " " }
        if model.findMatches.isEmpty { return "No matches" }
        return "\(model.findCurrentIndex + 1) of \(model.findMatches.count)"
    }
}

/// "Jump to date" popover (⌘J / the calendar button). Quick presets plus a
/// custom Rice-styled month grid — the stock graphical `DatePicker` fights the
/// dark palette with its system-blue chrome, so this is hand-drawn to match.
/// Tapping a day leaps the timeline to it; bounded to the past.
private struct JumpToDatePopover: View {
    let initialDate: Date
    let onJump: (Date) -> Void

    /// Day the thread is currently sitting on — highlighted as "you are here".
    @State private var anchorDay = Date()
    /// First-of-month the grid is showing.
    @State private var visibleMonth = Date()

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jump to Date")
                .riceFont(13, .semibold)
                .foregroundStyle(Rice.text)

            HStack(spacing: 6) {
                ForEach(presets, id: \.label) { preset in
                    Button(preset.label) { onJump(preset.date) }
                        .buttonStyle(RiceSubtleButtonStyle())
                }
            }

            monthHeader
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(gridDays, id: \.self) { day in
                    DayCell(
                        day: day,
                        inMonth: calendar.isDate(day, equalTo: visibleMonth, toGranularity: .month),
                        isFuture: calendar.startOfDay(for: day) > calendar.startOfDay(for: Date()),
                        isAnchor: calendar.isDate(day, inSameDayAs: anchorDay),
                        onTap: { onJump(day) }
                    )
                }
            }
        }
        .padding(16)
        .frame(width: 264)
        .background(Rice.base)
        .onAppear {
            anchorDay = min(initialDate, Date())
            visibleMonth = monthStart(for: anchorDay)
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(RiceIconButtonStyle())
            Spacer()
            Text(visibleMonth, format: .dateTime.month(.wide).year())
                .riceFont(12, .semibold)
                .foregroundStyle(Rice.text)
            Spacer()
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(RiceIconButtonStyle())
                .disabled(isShowingCurrentMonth)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 2) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .riceFont(9, .semibold)
                    .foregroundStyle(Rice.subtext0)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Calendar math

    private var presets: [(label: String, date: Date)] {
        let now = Date()
        return [
            ("1 week", calendar.date(byAdding: .weekOfYear, value: -1, to: now) ?? now),
            ("1 month", calendar.date(byAdding: .month, value: -1, to: now) ?? now),
            ("1 year", calendar.date(byAdding: .year, value: -1, to: now) ?? now),
        ]
    }

    /// Weekday initials, rotated to the locale's first weekday.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// A fixed 6-week grid covering `visibleMonth`, padded with the tail of the
    /// previous month and head of the next so weekdays line up.
    private var gridDays: [Date] {
        let start = monthStart(for: visibleMonth)
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: start) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: gridStart) }
    }

    private var isShowingCurrentMonth: Bool {
        monthStart(for: visibleMonth) >= monthStart(for: Date())
    }

    private func monthStart(for date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private func shiftMonth(_ delta: Int) {
        guard let shifted = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        // Never page past the current month — there's nothing in the future.
        visibleMonth = min(monthStart(for: shifted), monthStart(for: Date()))
    }
}

/// One day in the jump-to-date grid: dim outside the shown month, disabled in the
/// future, accent-ringed on the day the thread is currently anchored to.
private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isFuture: Bool
    let isAnchor: Bool
    let onTap: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var isHovering = false

    private let calendar = Calendar.current

    var body: some View {
        Button(action: onTap) {
            Text("\(calendar.component(.day, from: day))")
                .riceFont(11, isAnchor ? .semibold : .regular)
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 26)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .onHover { isHovering = $0 && !isFuture }
    }

    private var foreground: Color {
        if isFuture { return Rice.overlay0.opacity(0.5) }
        if isAnchor { return accent }
        return inMonth ? Rice.text : Rice.overlay0
    }

    private var background: Color {
        if isHovering { return Rice.surface0 }
        if isAnchor { return accent.opacity(0.16) }
        return .clear
    }
}

private struct DaySeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            RiceDivider()
            Text(label)
                .riceSectionHeader()
                .fixedSize()
            RiceDivider()
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: .now) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct MessageRow: View {
    let message: Message
    let startsGroup: Bool
    let endsGroup: Bool
    let isLatestOutgoing: Bool
    var isHighlighted = false
    var isFindMatch = false
    var isCurrentFindMatch = false
    var isSaved = false
    var isSelecting = false
    var isSelected = false
    var replyIDs: [MessageID] = []
    var onJump: (MessageID) -> Void = { _ in }
    var onToggleSaved: () -> Void = {}
    var onToggleSelection: () -> Void = {}
    var canReact = false
    var onReact: (ReactionKind) -> Void = { _ in }

    @Environment(\.riceAccent) private var accent
    @State private var isRevealed = false

    var body: some View {
        if isSelecting {
            selectableRow
        } else {
            bubbleRow
        }
    }

    /// In select mode: a leading checkbox, the bubble made inert (its own
    /// gestures/links suppressed), and the whole row a single tap target that
    /// toggles the tick. A faint accent wash marks the selected rows.
    private var selectableRow: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .riceFont(17)
                .foregroundStyle(isSelected ? accent : Rice.overlay0)
                .accessibilityLabel(isSelected ? "Selected" : "Not selected")
            bubbleRow
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelection)
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            isSelected ? accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var bubbleRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 90) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if startsGroup, !message.isOutgoing, let sender = message.sender {
                    HStack(spacing: 5) {
                        SenderBadge(participant: sender)
                        Text(sender.displayName ?? sender.handle)
                            .riceFont(10, .semibold)
                            .foregroundStyle(Rice.accent(seededBy: sender.id))
                    }
                    .padding(.leading, 6)
                    .padding(.top, 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let quoted = message.quoted {
                        QuotedReplyView(quoted: quoted, onJump: onJump)
                    } else if message.replyTo != nil {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext0)
                    }
                    if !message.text.isEmpty {
                        RichMessageText(text: message.text)
                            .riceFont(13)
                    }
                    if message.isEdited {
                        Text("edited")
                            .riceFont(9)
                            .foregroundStyle(Rice.overlay0)
                    }
                    ForEach(message.attachments) { attachment in
                        AttachmentView(attachment: attachment)
                    }
                }
                .privacyBlurred(revealed: isRevealed)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { isRevealed = $0 }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent.opacity(strongHighlight ? 1 : 0.5), lineWidth: borderWidth)
                )
                .animation(.easeOut(duration: 0.4), value: isHighlighted)
                .animation(.easeOut(duration: 0.2), value: isFindMatch)
                .animation(.easeOut(duration: 0.2), value: isCurrentFindMatch)
                .contextMenu {
                    if !message.text.isEmpty {
                        Button("Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
                    }
                    if canReact {
                        Menu("React") {
                            ForEach(Tapback.sendable, id: \.kind) { tapback in
                                Button {
                                    onReact(tapback.kind)
                                } label: {
                                    Text("\(tapback.glyph)  \(tapback.label)")
                                }
                            }
                        }
                    }
                    Button {
                        onToggleSaved()
                    } label: {
                        Label(isSaved ? "Remove from Saved" : "Save Message",
                              systemImage: isSaved ? "bookmark.slash" : "bookmark")
                    }
                    if let quoted = message.quoted {
                        Button("Jump to Original") { onJump(quoted.id) }
                    }
                }
                .overlay(alignment: message.isOutgoing ? .topLeading : .topTrailing) {
                    if !message.reactions.isEmpty {
                        ReactionBadges(reactions: message.reactions)
                            .offset(x: message.isOutgoing ? -10 : 10, y: -11)
                    }
                }
                // Star sits on the corner opposite the reactions so the two never
                // overlap; a bookmarked message reads at a glance in the timeline.
                .overlay(alignment: message.isOutgoing ? .topTrailing : .topLeading) {
                    if isSaved {
                        Image(systemName: "bookmark.fill")
                            .riceFont(9)
                            .foregroundStyle(accent)
                            .padding(3)
                            .background(Rice.mantle, in: Circle())
                            .offset(x: message.isOutgoing ? 7 : -7, y: -7)
                            .accessibilityLabel("Saved")
                    }
                }
                .padding(.top, message.reactions.isEmpty ? 0 : 11)

                if let previewURL {
                    InlineLinkPreview(url: previewURL)
                }

                if !replyIDs.isEmpty {
                    Button {
                        if let latest = replyIDs.last { onJump(latest) }
                    } label: {
                        Label(
                            replyIDs.count == 1 ? "1 reply" : "\(replyIDs.count) replies",
                            systemImage: "arrowshape.turn.up.left.fill"
                        )
                        .riceFont(9, .medium)
                        .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                }

                if endsGroup {
                    HStack(spacing: 4) {
                        Text(message.createdAt, format: .dateTime.hour().minute())
                            .foregroundStyle(Rice.overlay0)
                        if let status = deliveryStatus {
                            Text("· \(status)")
                                .foregroundStyle(message.deliveryState == .failed ? Rice.red : Rice.overlay1)
                        }
                    }
                    .riceFont(9)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            if !message.isOutgoing { Spacer(minLength: 90) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// Messages.app-style receipt on the newest outgoing message only;
    /// failures always surface.
    private var deliveryStatus: String? {
        guard message.isOutgoing else { return nil }
        if message.deliveryState == .failed { return "Not Delivered" }
        guard isLatestOutgoing else { return nil }
        if let readAt = message.readAt {
            return "Read \(readAt.formatted(.dateTime.hour().minute()))"
        }
        switch message.deliveryState {
        case .delivered: return "Delivered"
        case .sent: return "Sent"
        case .pending: return "Sending…"
        case .failed, .unknown: return nil
        }
    }

    private var bubbleColor: Color {
        message.isOutgoing ? accent.opacity(0.22) : Rice.surface0
    }

    /// The first link in the message body, previewed as an OG card under the
    /// bubble. Just the first — one card keeps a link-heavy message readable.
    private var previewURL: URL? {
        message.text.isEmpty ? nil : LinkExtractor.urls(in: message.text).first
    }

    /// A reveal flash or the current find match gets a full-strength accent
    /// outline; other find matches get a fainter one so the current one stands
    /// out while every match stays visible.
    private var strongHighlight: Bool {
        isHighlighted || isCurrentFindMatch
    }

    private var borderWidth: CGFloat {
        if strongHighlight { return 1.5 }
        if isFindMatch { return 1 }
        return 0
    }

    private var accessibilitySummary: String {
        let sender = message.isOutgoing ? "You" : (message.sender?.displayName ?? "Participant")
        let body = message.text.isEmpty ? "Attachment" : message.text
        return "\(sender), \(body), \(message.createdAt.formatted(date: .omitted, time: .shortened))"
    }
}

/// The quoted original above a threaded reply; clicking jumps to it.
private struct QuotedReplyView: View {
    let quoted: QuotedMessage
    let onJump: (MessageID) -> Void

    @Environment(\.riceAccent) private var accent

    var body: some View {
        Button {
            onJump(quoted.id)
        } label: {
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent.opacity(0.8))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(quoted.senderName)
                        .riceFont(10, .semibold)
                        .foregroundStyle(Rice.subtext1)
                    Text(snippet)
                        .riceFont(11)
                        .foregroundStyle(Rice.subtext0)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .padding(.vertical, 1)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .help("Jump to the original message")
        .accessibilityLabel("In reply to \(quoted.senderName): \(snippet)")
    }

    private var snippet: String {
        quoted.text.nonEmpty ?? (quoted.hasAttachments ? "Attachment" : "Earlier message")
    }
}

/// Tapbacks grouped by glyph, overlapping the bubble corner iMessage-style.
private struct ReactionBadges: View {
    let reactions: [MessageReaction]

    @Environment(\.riceAccent) private var accent

    var body: some View {
        HStack(spacing: 3) {
            ForEach(groups, id: \.glyph) { group in
                HStack(spacing: 3) {
                    Text(group.glyph)
                        .riceFont(10)
                    if group.count > 1 {
                        Text(String(group.count))
                            .riceFont(9, .semibold)
                            .foregroundStyle(Rice.subtext1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(group.includesMe ? accent.opacity(0.35) : Rice.surface1, in: Capsule())
                .overlay(Capsule().strokeBorder(Rice.base, lineWidth: 1.5))
                .help("\(group.glyph) \(group.senders.joined(separator: ", "))")
                .accessibilityLabel("\(group.glyph) reaction from \(group.senders.joined(separator: ", "))")
            }
        }
    }

    private struct ReactionGroup {
        let glyph: String
        let count: Int
        let includesMe: Bool
        let senders: [String]
    }

    private var groups: [ReactionGroup] {
        Dictionary(grouping: reactions, by: \.glyph)
            .map { glyph, items in
                ReactionGroup(
                    glyph: glyph,
                    count: items.count,
                    includesMe: items.contains(where: \.isFromMe),
                    senders: items.map(\.senderDisplayName)
                )
            }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.glyph < right.glyph
            }
    }
}

/// Width of the centered header's trailing action group, reported up so the
/// title's symmetric reserve can track it exactly.
private struct HeaderActionsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
