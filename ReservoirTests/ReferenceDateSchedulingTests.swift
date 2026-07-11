import XCTest
@testable import Reservoir

/// Direct coverage for `ReferenceDateScheduling.nextMidnight(after:calendar:)`, the pure
/// date math backing `ReferenceDateKeeper`'s midnight-boundary refresh (shared by
/// `TodayView` and `GoalsView` — see that type's doc comment).
final class ReferenceDateSchedulingTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    func testNextMidnightFromMidDayReturnsFollowingMidnight() {
        let midDay = date(2026, 1, 15, hour: 13, minute: 30)
        let result = ReferenceDateScheduling.nextMidnight(after: midDay, calendar: calendar)
        XCTAssertEqual(result, date(2026, 1, 16))
    }

    func testNextMidnightFromExactlyMidnightReturnsTheFollowingMidnightNotItself() {
        // `.nextTime` is strictly-after, so midnight-on-the-dot still rolls to the next
        // day's midnight, not returning the same instant.
        let midnight = date(2026, 1, 15)
        let result = ReferenceDateScheduling.nextMidnight(after: midnight, calendar: calendar)
        XCTAssertEqual(result, date(2026, 1, 16))
    }

    func testNextMidnightFromJustBeforeMidnightReturnsTheSameCalendarDaysMidnight() {
        let almostMidnight = date(2026, 1, 15, hour: 23, minute: 59, second: 59)
        let result = ReferenceDateScheduling.nextMidnight(after: almostMidnight, calendar: calendar)
        XCTAssertEqual(result, date(2026, 1, 16))
    }

    func testNextMidnightRollsOverAMonthBoundary() {
        let lastDayOfMonth = date(2026, 1, 31, hour: 12)
        let result = ReferenceDateScheduling.nextMidnight(after: lastDayOfMonth, calendar: calendar)
        XCTAssertEqual(result, date(2026, 2, 1))
    }
}
