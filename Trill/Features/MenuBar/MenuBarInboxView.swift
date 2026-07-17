import AppKit
import SwiftUI

/// Ambient presence surface: the dropdown shown from the menu-bar `NSStatusItem`.
/// A glanceable mini-inbox — recent threads with unread counts — so the full
/// window can stay closed. Clicking a thread reveals the main window on it.
///
/// This is deliberately app-level and read-only: it reuses `InboxModel`'s
/// already-loaded conversation list and never mutates anything except by
/// delegating a `select(_:)` to the shared model.
struct MenuBarInboxView: View {
    @ObservedObject var model: InboxModel
    @Environment(\.openWindow) private var openWindow

    /// How many recent threads the dropdown lists. Menu-bar surfaces are for a
    /// glance, not a full inbox — the window is one click away for the rest.
    private static let rowLimit = 8

    private var recent: [Conversation] { model.recentConversations(limit: Self.rowLimit) }

    /// Brings the main inbox window frontmost, reopening it if the user closed
    /// it. Called before mutating the model so the window is already up when the
    /// selection lands. Prefers an existing titled window — the menu-bar popover
    /// is a panel, so it's excluded — and only spawns a new one via `openWindow`
    /// when none survives.
    private func revealMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let existing = NSApp.windows.first { window in
            window.canBecomeMain && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        if let existing {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: TrillApp.mainWindowID)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            RiceDivider()

            if recent.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recent) { conversation in
                            MenuBarRow(
                                conversation: conversation,
                                showsUnread: model.hasVisibleUnread(conversation)
                            ) {
                                revealMainWindow()
                                model.select(conversation.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
            }

            RiceDivider()
            footer
        }
        .frame(width: 320)
        .background(Rice.mantle)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Messages")
                .riceFont(13, .semibold)
                .foregroundStyle(Rice.text)
            if model.unreadTotal > 0 {
                Text("\(model.unreadTotal)")
                    .riceFont(10, .bold)
                    .foregroundStyle(Rice.crust)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Rice.accent(named: "mauve"), in: Capsule())
                    .accessibilityLabel("\(model.unreadTotal) unread messages")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray")
                .riceFont(18)
                .foregroundStyle(Rice.overlay0)
            Text("No conversations yet")
                .riceFont(11)
                .foregroundStyle(Rice.subtext0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                revealMainWindow()
            } label: {
                Label("Open", systemImage: "macwindow")
                    .riceFont(11, .medium)
            }
            Spacer()
            Button {
                revealMainWindow()
                model.isComposePresented = true
            } label: {
                Label("New", systemImage: "square.and.pencil")
                    .riceFont(11, .medium)
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .riceFont(11, .medium)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Rice.subtext0)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One thread in the menu-bar dropdown. A trimmed cousin of the sidebar's
/// `ConversationRowButton` — same avatar/name/preview grammar, tighter for a
/// popover glance.
private struct MenuBarRow: View {
    let conversation: Conversation
    let showsUnread: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                AvatarView(conversation: conversation, size: 26)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(conversation.displayName)
                            .riceFont(12, showsUnread ? .semibold : .medium)
                            .foregroundStyle(Rice.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(CompactTime.string(from: conversation.lastActivity))
                            .riceFont(9)
                            .foregroundStyle(Rice.overlay0)
                    }

                    HStack(alignment: .top, spacing: 6) {
                        Text(conversation.lastMessagePreview)
                            .riceFont(10)
                            .foregroundStyle(Rice.subtext0)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if showsUnread, let count = conversation.unreadCount, count > 0 {
                            Text("\(count)")
                                .riceFont(9, .bold)
                                .foregroundStyle(Rice.crust)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Rice.accent(named: "mauve"), in: Capsule())
                                .accessibilityLabel("\(count) unread messages")
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                isHovering ? Rice.surface0.opacity(0.6) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(conversation.displayName), \(conversation.service.displayLabel)")
    }
}

/// The status-item glyph itself, shown in the menu bar. Observes the model so
/// the unread count tracks live inbox changes.
struct MenuBarLabel: View {
    @ObservedObject var model: InboxModel

    var body: some View {
        if model.unreadTotal > 0 {
            Label("\(model.unreadTotal)", systemImage: "message.fill")
        } else {
            Image(systemName: "message")
        }
    }
}
