import AppKit
import UserNotifications

/// Posts macOS notifications for incoming messages and routes notification
/// clicks back to the originating conversation.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    var openConversation: ((ConversationID) -> Void)?

    private(set) var isAuthorized = false
    private var didPrepare = false

    func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    func post(message: Message, conversationName: String) {
        guard isAuthorized, !message.isOutgoing else { return }
        let content = UNMutableNotificationContent()
        content.title = conversationName
        if let sender = message.sender?.displayName ?? message.sender?.handle,
           sender != conversationName {
            content.subtitle = sender
        }
        content.body = message.text.nonEmpty
            ?? (message.attachments.isEmpty ? "New message" : "Attachment")
        content.sound = .default
        content.threadIdentifier = message.conversationID.persistenceKey
        content.userInfo = ["conversationKey": message.conversationID.persistenceKey]
        let request = UNNotificationRequest(
            identifier: message.id.persistenceKey,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo["conversationKey"] as? String
        Task { @MainActor [weak self] in
            if let key, let id = ConversationID(persistenceKey: key) {
                NSApp.activate(ignoringOtherApps: true)
                self?.openConversation?(id)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The model only posts when the thread isn't focused, so a banner is
        // still wanted while the app is frontmost.
        completionHandler([.banner, .sound])
    }
}
