import SwiftUI

@main
struct NativeMessagesApp: App {
    @StateObject private var inboxModel: InboxModel
    @AppStorage("uiScale") private var uiScale = 1.0
    @AppStorage("accentName") private var accentName = "mauve"

    init() {
        _inboxModel = StateObject(wrappedValue: AppEnvironment.makeInboxModel())
    }

    var body: some Scene {
        WindowGroup {
            RicedRoot {
                InboxView(model: inboxModel)
                    .frame(minWidth: 820, minHeight: 560)
            }
        }
        .defaultSize(width: 1_080, height: 720)
        .windowStyle(.hiddenTitleBar)
        .commands {
            AppCommands(
                showSearch: { inboxModel.isSearchPresented = true },
                reload: { inboxModel.load() },
                toggleSidebar: { inboxModel.toggleSidebar() },
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
    }
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
