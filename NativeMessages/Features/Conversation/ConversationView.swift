import SwiftUI

struct ConversationView: View {
    @ObservedObject var model: ConversationModel
    @ObservedObject var composer: ComposerModel
    var density: DisplayDensity = .comfortable
    var headerLeadingInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            RiceDivider()
            MessageTimelineView(model: model, density: density)
            RiceDivider()
            ComposerView(model: composer)
        }
        .background(Rice.base)
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let conversation = model.conversation {
                AvatarView(conversation: conversation, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(model.conversation?.displayName ?? "Conversation")
                    .riceFont(14, .semibold)
                    .foregroundStyle(Rice.text)
                if let conversation = model.conversation {
                    Text(conversation.kind == .group
                         ? "\(conversation.participants.count) participants"
                         : (conversation.participants.first?.displayName ?? conversation.participants.first?.handle ?? "Direct conversation"))
                        .riceFont(10)
                        .foregroundStyle(Rice.subtext0)
                }
            }
            Spacer()
            if let service = model.conversation?.service {
                ServiceChip(service: service)
            }
        }
        .padding(.leading, 16 + headerLeadingInset)
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
                        LazyVStack(spacing: density.timelineSpacing) {
                            if model.nextBefore != nil {
                                loadOlderButton(proxy: proxy)
                            }

                            ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                                if startsDay(at: index) {
                                    DaySeparator(date: message.createdAt)
                                }
                                MessageRow(
                                    message: message,
                                    startsGroup: startsGroup(at: index),
                                    endsGroup: endsGroup(at: index)
                                )
                                .id(message.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .id(model.conversation?.id)
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

    @Environment(\.riceAccent) private var accent

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isOutgoing { Spacer(minLength: 90) }
            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                if startsGroup, !message.isOutgoing {
                    Text(message.sender?.displayName ?? "Participant")
                        .riceFont(10, .semibold)
                        .foregroundStyle(Rice.accent(seededBy: message.sender?.id ?? "participant"))
                        .padding(.leading, 10)
                        .padding(.top, 5)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let reply = message.replyTo {
                        Label("Reply to \(reply.externalGUID.prefix(8))…", systemImage: "arrowshape.turn.up.left")
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext0)
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .riceFont(13)
                            .foregroundStyle(Rice.text)
                            .textSelection(.enabled)
                    }
                    ForEach(message.attachments) { attachment in
                        AttachmentRow(attachment: attachment)
                    }
                    if !message.reactions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(message.reactions) { reaction in
                                Text(reaction.glyph)
                                    .riceFont(11)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Rice.surface1, in: Capsule())
                                    .accessibilityLabel("\(reaction.kind.rawValue) from \(reaction.senderDisplayName)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if endsGroup {
                    Text(message.createdAt, format: .dateTime.hour().minute())
                        .riceFont(9)
                        .foregroundStyle(Rice.overlay0)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 4)
                }
            }
            if !message.isOutgoing { Spacer(minLength: 90) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
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

private struct AttachmentRow: View {
    let attachment: MessageAttachment
    @Environment(\.riceAccent) private var accent
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isImage ? "photo" : "doc")
                .riceFont(12)
                .foregroundStyle(accent)
                .frame(width: 20 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .riceFont(12, .medium)
                    .foregroundStyle(Rice.text)
                    .lineLimit(1)
                Text(status)
                    .riceFont(10)
                    .foregroundStyle(attachment.availability == .missing ? Rice.red : Rice.subtext0)
            }
        }
        .padding(7)
        .background(Rice.crust.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        switch attachment.availability {
        case .available:
            if let byteCount = attachment.byteCount {
                return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
            }
            return "Available"
        case .missing: return "Attachment unavailable"
        case .downloadRequired: return "Download required"
        }
    }
}
