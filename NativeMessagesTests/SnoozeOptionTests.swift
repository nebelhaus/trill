import Foundation
import XCTest
@testable import NativeMessages

final class SnoozeOptionTests: XCTestCase {
    /// A fixed calendar (Gregorian, UTC) so the clock math is reproducible
    /// regardless of the test machine's locale or zone.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testRelativeOptionsAreSimpleOffsets() {
        // 2026-07-16 is a Thursday, 10:00 UTC.
        let now = date(2026, 7, 16, 10, 0)
        XCTAssertEqual(SnoozeOption.hour.wakeDate(from: now, calendar: calendar), now.addingTimeInterval(3600))
        XCTAssertEqual(SnoozeOption.threeHours.wakeDate(from: now, calendar: calendar), now.addingTimeInterval(3 * 3600))
    }

    func testThisEveningIsSixPMToday() {
        let now = date(2026, 7, 16, 10, 0)
        let wake = SnoozeOption.thisEvening.wakeDate(from: now, calendar: calendar)
        XCTAssertEqual(wake, date(2026, 7, 16, 18, 0))
    }

    func testThisEveningRollsToTomorrowWhenAlreadyPast() {
        // 20:00 is past the 18:00 threshold, so "this evening" tips forward.
        let now = date(2026, 7, 16, 20, 0)
        let wake = SnoozeOption.thisEvening.wakeDate(from: now, calendar: calendar)
        XCTAssertEqual(wake, date(2026, 7, 17, 18, 0))
        XCTAssertGreaterThan(wake, now)
    }

    func testTomorrowIsNextMorning() {
        let now = date(2026, 7, 16, 20, 0)
        let wake = SnoozeOption.tomorrow.wakeDate(from: now, calendar: calendar)
        XCTAssertEqual(wake, date(2026, 7, 17, 8, 0))
    }

    func testNextWeekIsComingMondayMorning() {
        // Thursday 2026-07-16 → the following Monday is 2026-07-20.
        let now = date(2026, 7, 16, 10, 0)
        let wake = SnoozeOption.nextWeek.wakeDate(from: now, calendar: calendar)
        XCTAssertEqual(wake, date(2026, 7, 20, 8, 0))
    }

    func testNextWeekFromMondayIsTheFollowingMonday() {
        // On a Monday, "next week" means seven days out, not today.
        let monday = date(2026, 7, 20, 9, 0)
        let wake = SnoozeOption.nextWeek.wakeDate(from: monday, calendar: calendar)
        XCTAssertEqual(wake, date(2026, 7, 27, 8, 0))
    }

    func testEveryOptionResolvesToTheFuture() {
        let now = date(2026, 7, 16, 23, 30)
        for option in SnoozeOption.allCases {
            XCTAssertGreaterThan(
                option.wakeDate(from: now, calendar: calendar), now,
                "\(option) should always wake in the future"
            )
        }
    }
}
