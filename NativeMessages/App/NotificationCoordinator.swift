import AppKit
import UserNotifications

/// Posts macOS notifications for incoming messages and routes notification
/// clicks back to the originating conversation.
@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    var openConversation: ((ConversationID) -> Void)?
    /// Invoked when the user types a reply into a notification's text field.
    var sendReply: ((ConversationID, String) -> Void)?

    private(set) var isAuthorized = false
    private var didPrepare = false

    private static let categoryID = "MESSAGE"
    private static let replyActionID = "REPLY"

    func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.messageCategory])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
            }
        }
    }

    /// A message notification that offers an inline "Reply" text field.
    private static var messageCategory: UNNotificationCategory {
        let reply = UNTextInputNotificationAction(
            identifier: replyActionID,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply…"
        )
        return UNNotificationCategory(
            identifier: categoryID,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
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
        content.categoryIdentifier = Self.categoryID
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
        let reply = (response as? UNTextInputNotificationResponse)
            .map(\.userText)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor [weak self] in
            guard let key, let id = ConversationID(persistenceKey: key) else { return }
            if let reply, !reply.isEmpty {
                // Inline reply: send without stealing focus from the user's
                // current app — the whole point is staying in the banner.
                self?.sendReply?(id, reply)
            } else {
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
