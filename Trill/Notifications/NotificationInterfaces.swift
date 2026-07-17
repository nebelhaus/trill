import Foundation

struct NotificationEvent: Hashable, Sendable {
    let messageID: MessageID
    let conversationID: ConversationID
    let receivedAt: Date
}

enum NotificationDeliveryMode: String, Sendable {
    case immediate
    case coalesced
    case digest
    case badgeOnly
    case suppressed
}

struct NotificationDecision: Sendable {
    let mode: NotificationDeliveryMode
    let reasonCode: String
}

protocol NotificationPolicyEvaluating: Sendable {
    func decision(for event: NotificationEvent) async -> NotificationDecision
}

protocol NotificationDelivering: Sendable {
    func deliver(_ event: NotificationEvent, decision: NotificationDecision) async throws
}

