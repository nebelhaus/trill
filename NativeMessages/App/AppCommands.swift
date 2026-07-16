import SwiftUI

struct AppCommands: Commands {
    let newMessage: () -> Void
    let showPalette: () -> Void
    let showSearch: () -> Void
    let showLibrary: () -> Void
    let reload: () -> Void
    let toggleSidebar: () -> Void
    let togglePin: () -> Void
    let toggleUnreadFilter: () -> Void
    let toggleNeedsReplyFilter: () -> Void
    let selectPinned: (Int) -> Void
    let useFixture: () -> Void
    let useMessages: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomReset: () -> Void

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message", action: newMessage)
                .keyboardShortcut("n", modifiers: .command)
        }

        CommandMenu("Messages") {
            Button("Command Palette…", action: showPalette)
                .keyboardShortcut("k", modifiers: .command)
            Button("Search…", action: showSearch)
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Library…", action: showLibrary)
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Reload", action: reload)
                .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Pin/Unpin Conversation", action: togglePin)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Unread Only", action: toggleUnreadFilter)
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Needs Reply Only", action: toggleNeedsReplyFilter)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { slot in
                Button("Pinned Conversation \(slot)") { selectPinned(slot - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(slot)")), modifiers: .command)
            }
            Divider()
            Menu("Provider") {
                Button("Synthetic Fixtures", action: useFixture)
                Button("Messages", action: useMessages)
            }
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Conversation Sidebar", action: toggleSidebar)
                .keyboardShortcut("s", modifiers: [.command, .control])
            Divider()
            Button("Zoom In", action: zoomIn)
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out", action: zoomOut)
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size", action: zoomReset)
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
