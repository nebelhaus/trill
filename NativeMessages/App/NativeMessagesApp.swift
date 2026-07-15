import SwiftUI

@main
struct NativeMessagesApp: App {
    @StateObject private var inboxModel: InboxModel
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("accentName") private var accentName = "mauve"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    init() {
        _inboxModel = StateObject(wrappedValue: AppEnvironment.makeInboxModel())
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            RicedRoot {
                InboxView(model: inboxModel)
                    // Floor low enough to dock the window to ~1/3 of a screen.
                    // Below InboxView's compact breakpoint the layout folds to a
                    // single column, so it stays usable all the way down.
                    .frame(minWidth: 360, minHeight: 480)
            }
        }
        .defaultSize(width: 1_080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(
                newMessage: { inboxModel.isComposePresented = true },
                showPalette: { inboxModel.isPalettePresented = true },
                showSearch: { inboxModel.isSearchPresented = true },
                reload: { inboxModel.load() },
                toggleSidebar: { inboxModel.toggleSidebar() },
                togglePin: { inboxModel.toggleSelectedPin() },
                toggleUnreadFilter: { inboxModel.showsUnreadOnly.toggle() },
                toggleNeedsReplyFilter: { inboxModel.showsNeedsReplyOnly.toggle() },
                selectPinned: { inboxModel.selectPinned(at: $0) },
                useFixture: { inboxModel.switchProvider(to: .fixture) },
                useMessages: { inboxModel.switchProvider(to: .messages) },
                zoomIn: { uiScale = min(UIZoom.range.upperBound, uiScale + UIZoom.step) },
                zoomOut: { uiScale = max(UIZoom.range.lowerBound, uiScale - UIZoom.step) },
                zoomReset: { uiScale = 1.0 }
            )
        }

        Settings {
            RicedRoot {
                SettingsView()
            }
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            RicedRoot {
                MenuBarInboxView(model: inboxModel)
            }
        } label: {
            MenuBarLabel(model: inboxModel)
        }
        .menuBarExtraStyle(.window)
    }

    /// Shared between the `WindowGroup` and the menu-bar view's reopen path.
    static let mainWindowID = "main"
}

/// Root theming wrapper. Lives at the view level (not the App struct) so
/// AppStorage changes from menu commands re-render the scene content.
private struct RicedRoot<Content: View>: View {
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("accentName") private var accentName = "mauve"
    @ViewBuilder let content: Content

    var body: some View {
        content
            .environment(\.uiScale, uiScale)
            .environment(\.riceAccent, Rice.accent(named: accentName))
            .tint(Rice.accent(named: accentName))
            .preferredColorScheme(.dark)
    }
}
