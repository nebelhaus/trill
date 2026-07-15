import Foundation

/// Pure triage logic for the "Needs reply" filter, kept out of the view/model
/// so it can be unit-tested directly over fixtures.
///
/// A conversation needs a reply when its last message came from the other party
/// (`lastMessageFromMe == false`) and enough time has elapsed since then that it
/// counts as unanswered. This is the app's triage view: who is waiting on you.
enum NeedsReply {
    /// A thread only counts as needing a reply once its last inbound message has
    /// gone unanswered for at least this long — recent back-and-forth isn't a
    /// backlog. Three hours keeps the view about genuine follow-ups.
    static let defaultThreshold: TimeInterval = 3 * 60 * 60

    static func needsReply(
        _ conversation: Conversation,
        now: Date,
        threshold: TimeInterval = defaultThreshold
    ) -> Bool {
        guard !conversation.lastMessageFromMe else { return false }
        return now.timeIntervalSince(conversation.lastActivity) >= threshold
    }

    /// Conversations awaiting a reply, most-overdue first so the threads that
    /// have waited longest surface at the top of the triage view.
    static func filter(
        _ conversations: [Conversation],
        now: Date,
        threshold: TimeInterval = defaultThreshold
    ) -> [Conversation] {
        conversations
            .filter { needsReply($0, now: now, threshold: threshold) }
            .sorted { $0.lastActivity < $1.lastActivity }
    }
}
