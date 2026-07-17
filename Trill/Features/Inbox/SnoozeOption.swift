import Foundation

/// The preset durations offered in the Snooze menu. Kept as a pure value type
/// with deterministic date math (given a `now` and a `Calendar`) so the
/// resurface time is unit-testable without a clock — the InboxModel scheduler
/// and the context menu both read `wakeDate(from:calendar:)`.
enum SnoozeOption: String, CaseIterable, Identifiable, Sendable {
    case hour
    case threeHours
    case thisEvening
    case tomorrow
    case nextWeek

    var id: String { rawValue }

    /// Evening is defined as 6pm, the workday-to-personal handoff.
    static let eveningHour = 18
    /// Morning wake for "tomorrow" / "next week" snoozes.
    static let morningHour = 8

    var title: String {
        switch self {
        case .hour: "In 1 Hour"
        case .threeHours: "In 3 Hours"
        case .thisEvening: "This Evening"
        case .tomorrow: "Tomorrow"
        case .nextWeek: "Next Week"
        }
    }

    var systemImage: String {
        switch self {
        case .hour, .threeHours: "clock"
        case .thisEvening: "moon"
        case .tomorrow: "sunrise"
        case .nextWeek: "calendar"
        }
    }

    /// When a thread snoozed *now* should resurface. Always strictly in the
    /// future: the two clock-anchored options (evening, tomorrow/next-week
    /// mornings) roll forward if that time has already passed today.
    func wakeDate(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour:
            return now.addingTimeInterval(3600)
        case .threeHours:
            return now.addingTimeInterval(3 * 3600)
        case .thisEvening:
            let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: now) ?? now
            // Already past 6pm → tip into tomorrow evening so it's never in the past.
            return evening > now ? evening : (calendar.date(byAdding: .day, value: 1, to: evening) ?? evening)
        case .tomorrow:
            let nextDay = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: nextDay) ?? nextDay
        case .nextWeek:
            // The coming Monday at the morning hour. `weekday` is 1=Sunday…7=Saturday.
            let weekday = calendar.component(.weekday, from: now)
            let daysUntilMonday = ((9 - weekday) % 7 == 0) ? 7 : (9 - weekday) % 7
            let monday = calendar.date(byAdding: .day, value: daysUntilMonday, to: now) ?? now
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: monday) ?? monday
        }
    }
}
