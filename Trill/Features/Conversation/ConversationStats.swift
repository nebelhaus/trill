import Foundation

/// Everything the stats panel shows for one thread, derived purely from message
/// timestamps and direction. Impossible in Apple's Messages, cheap for us: we
/// already read `date` and `is_from_me` for every row.
struct ConversationStats: Equatable, Sendable {
    let totalMessages: Int
    let fromMeCount: Int
    let fromThemCount: Int
    let firstMessageDate: Date?
    let lastMessageDate: Date?
    /// Median time it takes *me* to reply after they've written — nil until
    /// there's at least one such turn.
    let yourMedianReply: TimeInterval?
    /// Median time it takes *them* to reply after I've written.
    let theirMedianReply: TimeInterval?
    /// Hour of day (0–23, local) that carries the most messages, ties broken
    /// toward the earlier hour. Nil when the thread is empty.
    let busiestHour: Int?
    /// Consecutive calendar days with at least one message, counting back from
    /// the most recent active day — but only while that streak reaches today or
    /// yesterday. A thread last touched a week ago has a current streak of 0.
    let currentStreakDays: Int

    static let empty = ConversationStats(
        totalMessages: 0, fromMeCount: 0, fromThemCount: 0,
        firstMessageDate: nil, lastMessageDate: nil,
        yourMedianReply: nil, theirMedianReply: nil,
        busiestHour: nil, currentStreakDays: 0
    )

    /// Share of messages sent by me, 0…1. Nil for an empty thread so the view
    /// can hide the ratio rather than draw a meaningless 0%.
    var yourShare: Double? {
        totalMessages > 0 ? Double(fromMeCount) / Double(totalMessages) : nil
    }
}

/// Pure aggregation for the conversation stats panel, kept out of the view/model
/// so it can be unit-tested directly over sample arrays — mirrors how
/// `NeedsReply` isolates its triage logic.
enum ConversationStatsBuilder {
    /// Builds the stats from message samples in any order. `now` and `calendar`
    /// are injected so streak math is testable without touching the wall clock.
    static func build(
        from samples: [MessageStatSample],
        now: Date,
        calendar: Calendar = .current
    ) -> ConversationStats {
        guard !samples.isEmpty else { return .empty }
        let ordered = samples.sorted { $0.date < $1.date }

        let fromMe = ordered.lazy.filter(\.isFromMe).count

        // Reply latency: only turn *switches* count as a reply, so a burst of
        // consecutive messages from one side isn't mistaken for a fast response.
        var yourGaps: [TimeInterval] = []
        var theirGaps: [TimeInterval] = []
        for (previous, current) in zip(ordered, ordered.dropFirst()) where current.isFromMe != previous.isFromMe {
            let gap = current.date.timeIntervalSince(previous.date)
            if current.isFromMe { yourGaps.append(gap) } else { theirGaps.append(gap) }
        }

        // Busiest hour: bucket by local hour, prefer the earlier hour on a tie.
        var hourCounts = [Int: Int](minimumCapacity: 24)
        for sample in ordered {
            let hour = calendar.component(.hour, from: sample.date)
            hourCounts[hour, default: 0] += 1
        }
        let busiestHour = hourCounts
            .max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?
            .key

        return ConversationStats(
            totalMessages: ordered.count,
            fromMeCount: fromMe,
            fromThemCount: ordered.count - fromMe,
            firstMessageDate: ordered.first?.date,
            lastMessageDate: ordered.last?.date,
            yourMedianReply: median(yourGaps),
            theirMedianReply: median(theirGaps),
            busiestHour: busiestHour,
            currentStreakDays: streak(ordered, now: now, calendar: calendar)
        )
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Consecutive active days ending at the most recent one, but only "current"
    /// when that run still reaches today or yesterday — otherwise the streak is
    /// broken and reads as 0.
    private static func streak(
        _ ordered: [MessageStatSample],
        now: Date,
        calendar: Calendar
    ) -> Int {
        let activeDays = Set(ordered.map { calendar.startOfDay(for: $0.date) })
        guard let mostRecent = activeDays.max() else { return 0 }
        let today = calendar.startOfDay(for: now)
        guard let daysSince = calendar.dateComponents([.day], from: mostRecent, to: today).day,
              daysSince <= 1 else { return 0 }

        var count = 0
        var cursor = mostRecent
        while activeDays.contains(cursor) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }
}
