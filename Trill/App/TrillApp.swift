import SwiftUI

@main
struct TrillApp: App {
    @StateObject private var inboxModel: InboxModel
    @StateObject private var snippetStore: SnippetStore
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("accentName") private var accentName = "mauve"
    @AppStorage("showMenuBarItem") private var showMenuBarItem = true

    init() {
        let services = AppEnvironment.makeServices()
        _inboxModel = StateObject(wrappedValue: services.inbox)
        _snippetStore = StateObject(wrappedValue: services.snippets)

        // Flush the in-progress draft before the process exits. The composer
        // saves on a 250ms debounce, so text typed in the moment before ⌘Q
        // would otherwise die with its unfired save task. Delivered on the main
        // queue, so the @MainActor hop is safe.
        let inbox = services.inbox
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { inbox.composerModel.flushDraft() }
        }
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
                showLibrary: { inboxModel.isLibraryPresented = true },
                showStyleProfile: { inboxModel.isStyleProfilePresented = true },
                showShortcuts: { inboxModel.isShortcutsPresented.toggle() },
                findInConversation: { inboxModel.conversationModel.beginFind() },
                jumpToDate: { inboxModel.conversationModel.beginJumpToDate() },
                findNext: { inboxModel.conversationModel.findNext() },
                findPrevious: { inboxModel.conversationModel.findPrevious() },
                goBack: { inboxModel.goBack() },
                goForward: { inboxModel.goForward() },
                canGoBack: inboxModel.canGoBack,
                canGoForward: inboxModel.canGoForward,
                openInNewTab: { inboxModel.openInNewTab(inboxModel.selectedConversationID) },
                nextTab: { inboxModel.nextTab() },
                previousTab: { inboxModel.previousTab() },
                closeTab: { inboxModel.selectedConversationID.map { inboxModel.closeTab($0) } },
                hasMultipleTabs: inboxModel.openTabs.count >= 2,
                reload: { inboxModel.load() },
                toggleSidebar: { inboxModel.toggleSidebar() },
                togglePin: { inboxModel.toggleSelectedPin() },
                toggleVIP: { inboxModel.toggleSelectedVIP() },
                toggleUnreadFilter: { inboxModel.showsUnreadOnly.toggle() },
                toggleNeedsReplyFilter: { inboxModel.showsNeedsReplyOnly.toggle() },
                toggleDraftsFilter: { inboxModel.showsDraftsOnly.toggle() },
                hasDrafts: inboxModel.hasDrafts,
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
                    .environmentObject(snippetStore)
                    .environmentObject(inboxModel)
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
