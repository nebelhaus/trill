import AppKit
import SwiftUI

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

    @State private var isGalleryPresented = false

    /// Width kept clear on the trailing edge (pin + gallery + service chip) so
    /// the title never collides with the header actions.
    private static let actionsReserve: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            header
            RiceDivider()
            MessageTimelineView(model: model, density: density)
            RiceDivider()
            ComposerView(model: composer)
        }
        .background(Rice.base)
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
    }

    private var header: some View {
        ZStack {
            // Avatar + title. Centered in the bar when the sidebar is collapsed,
            // left-aligned when it's open. Laid out horizontally either way so
            // the bar keeps its height.
            HStack(spacing: 10) {
                if let conversation = model.conversation {
                    AvatarView(conversation: conversation, size: 26)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.conversation?.displayName ?? "Conversation")
                        .riceFont(14, .semibold)
                        .foregroundStyle(Rice.text)
                        .lineLimit(1)
                    if let conversation = model.conversation {
                        Text(conversation.kind == .group
                             ? "\(conversation.participants.count) participants"
                             : (conversation.participants.first?.displayName ?? conversation.participants.first?.handle ?? "Direct conversation"))
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext0)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: isSidebarCollapsed ? .center : .leading)
            // Reserve room for the trailing actions so a long title truncates
            // instead of sliding under them. Symmetric when centered so the
            // title stays optically on the window's midline.
            .padding(.leading, isSidebarCollapsed ? Self.actionsReserve : 0)
            .padding(.trailing, Self.actionsReserve)

            // Actions stay pinned to the trailing edge in both states.
            HStack(spacing: 10) {
                Spacer()
                Button(action: onTogglePin) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help(isPinned ? "Unpin conversation (⇧⌘P)" : "Pin conversation (⇧⌘P)")
                Button {
                    isGalleryPresented = true
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                }
                .buttonStyle(RiceIconButtonStyle())
                .help("Media gallery")
                if let service = model.conversation?.service {
                    ServiceChip(service: service)
                }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }
}

private struct MessageTimelineView: View {
    @ObservedObject var model: ConversationModel
    let density: DisplayDensity

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
                                    replyIDs: replies[message.id] ?? [],
                                    onJump: { target in
                                        withAnimation(.easeInOut(duration: 0.25)) {
                                            proxy.scrollTo(target, anchor: .center)
                                        }
                                    }
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
    var replyIDs: [MessageID] = []
    var onJump: (MessageID) -> Void = { _ in }

    @Environment(\.riceAccent) private var accent

    var body: some View {
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
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accent, lineWidth: isHighlighted ? 1.5 : 0)
                )
                .animation(.easeOut(duration: 0.4), value: isHighlighted)
                .contextMenu {
                    if !message.text.isEmpty {
                        Button("Copy Text") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        }
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
                .padding(.top, message.reactions.isEmpty ? 0 : 11)

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
