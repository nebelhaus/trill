import XCTest
@testable import Trill

final class ConversationStatsTests: XCTestCase {
    /// UTC so hour-of-day and day-boundary math is independent of the test
    /// machine's locale.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-07-15 00:00:00 UTC, the anchor most cases build off.
    private let epoch = Date(timeIntervalSince1970: 1_784_073_600)

    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private func sample(_ offset: TimeInterval, fromMe: Bool) -> MessageStatSample {
        MessageStatSample(date: at(offset), isFromMe: fromMe)
    }

    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 86_400

    func testEmptyInputYieldsEmptyStats() {
        XCTAssertEqual(ConversationStatsBuilder.build(from: [], now: epoch, calendar: calendar), .empty)
    }

    func testCountsAndBalance() {
        let samples = [
            sample(0, fromMe: false),
            sample(60, fromMe: true),
            sample(120, fromMe: true),
            sample(180, fromMe: false),
        ]
        let stats = ConversationStatsBuilder.build(from: samples, now: at(300), calendar: calendar)
        XCTAssertEqual(stats.totalMessages, 4)
        XCTAssertEqual(stats.fromMeCount, 2)
        XCTAssertEqual(stats.fromThemCount, 2)
        XCTAssertEqual(stats.yourShare, 0.5)
    }

    /// Only turn switches count as a reply: back-to-back messages from the same
    /// side don't inflate the latency, and each side's median is separate.
    func testMedianReplyUsesTurnSwitchesPerSide() {
        let samples = [
            sample(0, fromMe: false),          // them
            sample(5 * 60, fromMe: true),      // my reply after 5m
            sample(6 * 60, fromMe: true),      // my follow-up — not a switch
            sample(26 * 60, fromMe: false),    // their reply after 20m
            sample(36 * 60, fromMe: true),     // my reply after 10m
        ]
        let stats = ConversationStatsBuilder.build(from: samples, now: at(40 * 60), calendar: calendar)
        // My replies: 5m and 10m → median 7.5m. Theirs: a single 20m.
        XCTAssertEqual(stats.yourMedianReply, 7.5 * 60)
        XCTAssertEqual(stats.theirMedianReply, 20 * 60)
    }

    func testMedianReplyNilWhenNoSwitches() {
        let samples = [sample(0, fromMe: true), sample(60, fromMe: true)]
        let stats = ConversationStatsBuilder.build(from: samples, now: at(120), calendar: calendar)
        XCTAssertNil(stats.yourMedianReply)
        XCTAssertNil(stats.theirMedianReply)
    }

    /// Input arrives unsorted; the builder orders by date before pairing turns.
    func testUnsortedInputIsOrdered() {
        let samples = [
            sample(36 * 60, fromMe: true),
            sample(0, fromMe: false),
            sample(6 * 60, fromMe: true),
        ]
        let stats = ConversationStatsBuilder.build(from: samples, now: at(40 * 60), calendar: calendar)
        XCTAssertEqual(stats.firstMessageDate, at(0))
        XCTAssertEqual(stats.lastMessageDate, at(36 * 60))
        // First switch is the 6m reply; the 36m message follows my own 6m one.
        XCTAssertEqual(stats.yourMedianReply, 6 * 60)
    }

    /// The most populated local hour wins; ties resolve to the earlier hour.
    func testBusiestHour() {
        let samples = [
            sample(9 * hour, fromMe: false),
            sample(9 * hour + 60, fromMe: true),
            sample(14 * hour, fromMe: false),
        ]
        let stats = ConversationStatsBuilder.build(from: samples, now: at(15 * hour), calendar: calendar)
        XCTAssertEqual(stats.busiestHour, 9)
    }

    /// Consecutive days up to "now" count; a gap ends the streak.
    func testCurrentStreakCountsBackFromToday() {
        let now = at(20 * hour) // sometime on 2026-07-15
        let samples = [
            sample(-2 * day, fromMe: true),   // 07-13
            sample(-1 * day, fromMe: false),  // 07-14
            sample(10 * hour, fromMe: true),  // 07-15 (today)
        ]
        let stats = ConversationStatsBuilder.build(from: samples, now: now, calendar: calendar)
        XCTAssertEqual(stats.currentStreakDays, 3)
    }

    /// A one-day gap before today still counts: yesterday's activity keeps the
    /// streak "current" even if nothing has landed today yet.
    func testStreakCurrentWhenLastActiveYesterday() {
        let now = at(5 * hour) // early on 2026-07-15, nothing today
        let samples = [
            sample(-1 * day, fromMe: false), // 07-14
            sample(-1 * day + hour, fromMe: true),
        ]
        let stats = ConversationStatsBuilder.build(from: samples, now: now, calendar: calendar)
        XCTAssertEqual(stats.currentStreakDays, 1)
    }

    /// If the most recent message is older than yesterday, the streak is broken.
    func testStreakZeroWhenStale() {
        let now = at(5 * hour)
        let samples = [sample(-5 * day, fromMe: false), sample(-4 * day, fromMe: true)]
        let stats = ConversationStatsBuilder.build(from: samples, now: now, calendar: calendar)
        XCTAssertEqual(stats.currentStreakDays, 0)
    }

    /// End-to-end through the fixture provider: the real samples aggregate into
    /// a coherent, non-empty panel.
    func testFixtureProviderProducesStats() async throws {
        let provider = FixtureProvider()
        let conversations = try await provider.conversations(page: ConversationPageRequest(limit: 100)).conversations
        let avery = try XCTUnwrap(conversations.first { $0.displayName == "Avery Chen" })
        let samples = try await provider.statSamples(in: avery.id)
        XCTAssertFalse(samples.isEmpty)

        let stats = ConversationStatsBuilder.build(from: samples, now: avery.lastActivity, calendar: calendar)
        XCTAssertEqual(stats.totalMessages, samples.count)
        XCTAssertEqual(stats.fromMeCount + stats.fromThemCount, samples.count)
    }
}
