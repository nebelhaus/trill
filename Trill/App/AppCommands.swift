import SwiftUI

struct AppCommands: Commands {
    let newMessage: () -> Void
    let showPalette: () -> Void
    let showSearch: () -> Void
    let showLibrary: () -> Void
    let showShortcuts: () -> Void
    let findInConversation: () -> Void
    let jumpToDate: () -> Void
    let findNext: () -> Void
    let findPrevious: () -> Void
    let goBack: () -> Void
    let goForward: () -> Void
    let canGoBack: Bool
    let canGoForward: Bool
    let reload: () -> Void
    let toggleSidebar: () -> Void
    let togglePin: () -> Void
    let toggleVIP: () -> Void
    let toggleUnreadFilter: () -> Void
    let toggleNeedsReplyFilter: () -> Void
    let toggleDraftsFilter: () -> Void
    let hasDrafts: Bool
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
            Button("Find in Conversation…", action: findInConversation)
                .keyboardShortcut("f", modifiers: .command)
            Button("Jump to Date…", action: jumpToDate)
                .keyboardShortcut("j", modifiers: .command)
            Button("Find Next", action: findNext)
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous", action: findPrevious)
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Button("Back", action: goBack)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!canGoBack)
            Button("Forward", action: goForward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!canGoForward)
            Button("Reload", action: reload)
                .keyboardShortcut("r", modifiers: .command)
            Button("Keyboard Shortcuts", action: showShortcuts)
                .keyboardShortcut("/", modifiers: .command)
            Divider()
            Button("Add/Remove VIP", action: toggleVIP)
                .keyboardShortcut("v", modifiers: [.command, .control])
            Button("Pin/Unpin Conversation", action: togglePin)
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Unread Only", action: toggleUnreadFilter)
                .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Needs Reply Only", action: toggleNeedsReplyFilter)
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Drafts Only", action: toggleDraftsFilter)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!hasDrafts)
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
