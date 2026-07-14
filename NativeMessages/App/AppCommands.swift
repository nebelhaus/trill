import SwiftUI

struct AppCommands: Commands {
    let newMessage: () -> Void
    let showSearch: () -> Void
    let reload: () -> Void
    let toggleSidebar: () -> Void
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
            Button("Search…", action: showSearch)
                .keyboardShortcut("k", modifiers: .command)
            Button("Reload", action: reload)
                .keyboardShortcut("r", modifiers: .command)
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
