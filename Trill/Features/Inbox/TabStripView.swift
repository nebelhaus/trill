import SwiftUI
import UniformTypeIdentifiers

/// The in-app conversation tab strip (browser model): one chip per open thread,
/// shown across the top of the detail pane only when two or more tabs are open.
/// Clicking a chip switches instantly — each tab keeps its own warm timeline in
/// `InboxModel.tabModels` — and the hover close button drops it. Chips size to
/// their label and reorder by drag & drop. Backed by `InboxModel.openTabs`.
struct TabStripView: View {
    @ObservedObject var model: InboxModel
    /// Extra leading room so the first chip clears the traffic lights when the
    /// sidebar is collapsed.
    var leadingInset: CGFloat = 0
    /// The chip currently being dragged, shared with each chip's drop delegate so
    /// hovering one reorders it relative to the dragged tab. Nil at rest. Purely
    /// bookkeeping for the reorder — never drives a persistent visual, so a drag
    /// abandoned off-strip can't wedge a chip into a stuck state.
    @State private var dragging: ConversationID?

    /// The chips sit below the window's transparent-titlebar drag region so a
    /// press-drag reorders instead of moving the window. AppKit won't let a
    /// SwiftUI gesture view opt out of that drag, so we reserve this slim,
    /// still-draggable clearance above the chips as the only reliable escape.
    private static let titlebarClearance: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.titlebarClearance)
            HStack(spacing: 6) {
                ForEach(tabs) { conversation in
                    TabChip(
                        title: conversation.displayName,
                        isActive: model.isActiveTab(conversation.id),
                        showsUnread: model.hasVisibleUnread(conversation),
                        onSelect: { model.activateTab(conversation.id) },
                        onClose: { model.closeTab(conversation.id) }
                    )
                    .onDrag {
                        dragging = conversation.id
                        return NSItemProvider(object: conversation.id.persistenceKey as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabDropDelegate(
                        item: conversation.id,
                        dragging: $dragging,
                        move: { dragged, target in
                            withAnimation(.easeInOut(duration: 0.15)) { model.moveTab(dragged, to: target) }
                        }
                    ))
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 10 + leadingInset)
            .padding(.trailing, 10)
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rice.mantle)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Rice.surface0)
                .frame(height: 1)
        }
        // Catch a drop released over the strip's empty space so the drag session
        // ends cleanly (the reorder itself already happened via `dropEntered`).
        .onDrop(of: [.text], delegate: StripDropDelegate(dragging: $dragging))
    }

    /// Open tabs resolved to their conversations, in strip order. A tab whose
    /// conversation has dropped out of the loaded list is skipped defensively.
    private var tabs: [Conversation] {
        model.openTabs.compactMap { id in model.conversations.first { $0.id == id } }
    }
}

/// A single tab chip. The close button reveals on hover (and stays visible on the
/// active tab) so the strip reads calmly at rest.
private struct TabChip: View {
    let title: String
    let isActive: Bool
    let showsUnread: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.riceAccent) private var accent
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if showsUnread {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Unread")
            }
            Text(title)
                .riceFont(12, isActive ? .semibold : .medium)
                .foregroundStyle(isActive ? Rice.text : Rice.subtext0)
                .lineLimit(1)
                .fixedSize()
            closeButton
                .opacity(isHovering || isActive ? 1 : 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .riceFont(8, .bold)
                .foregroundStyle(Rice.subtext0)
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close tab (⌘W)")
        .accessibilityLabel("Close \(title)")
    }

    private var background: Color {
        if isActive { return accent.opacity(0.18) }
        if isHovering { return Rice.surface0.opacity(0.55) }
        return Rice.surface0.opacity(0.28)
    }
}

/// Reorders the strip as a dragged chip hovers over `item`: each `dropEntered`
/// hops the dragged tab one slot toward where it's pointing. `performDrop` ends
/// the drag; the actual drop payload is ignored (order lives in `openTabs`).
private struct TabDropDelegate: DropDelegate {
    let item: ConversationID
    @Binding var dragging: ConversationID?
    let move: (ConversationID, ConversationID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item else { return }
        move(dragging, item)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Strip-level catch-all so a drag released over empty strip space still ends the
/// session, clearing `dragging`.
private struct StripDropDelegate: DropDelegate {
    @Binding var dragging: ConversationID?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
