import XCTest
@testable import Reservoir

final class WidgetTimelinePlannerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testPhaseSameDayIsCurrent() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 9), at: date(27, 23), calendar: calendar), .current)
    }

    func testPhaseNextDayIsEstimate() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 20), at: date(28, 1), calendar: calendar), .estimate)
    }

    func testPhaseAfter36HoursNeedsRefresh() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 1), at: date(28, 13), calendar: calendar), .needsRefresh)
    }

    func testPhaseTwoCalendarDaysLaterNeedsRefreshEvenUnder36Hours() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 23), at: date(29, 5), calendar: calendar), .needsRefresh)
    }

    func testPhaseClockSkewIsCurrent() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 9), at: date(27, 8), calendar: calendar), .current)
    }

    func testCaptionThresholdIsThreeHours() {
        XCTAssertFalse(WidgetTimelinePlanner.showsUpdatedCaption(generatedAt: date(27, 9), at: date(27, 11, 59)))
        XCTAssertTrue(WidgetTimelinePlanner.showsUpdatedCaption(generatedAt: date(27, 9), at: date(27, 12)))
    }

    func testEntriesCoverCaptionMidnightAndRefresh() {
        let generated = date(27, 20)
        let entries = WidgetTimelinePlanner.entries(generatedAt: generated, now: date(27, 20, 1), calendar: calendar)
        XCTAssertEqual(entries.map(\.date), [date(27, 20, 1), date(27, 23), date(28, 0), date(29, 0), date(29, 8)])
        XCTAssertEqual(entries.map(\.phase), [.current, .current, .estimate, .needsRefresh, .needsRefresh])
        XCTAssertEqual(entries.map(\.showsUpdatedCaption), [false, true, true, true, true])
    }

    func testEntriesForOldSnapshotIsSingleRefreshEntry() {
        let entries = WidgetTimelinePlanner.entries(generatedAt: date(20, 9), now: date(27, 9), calendar: calendar)
        XCTAssertEqual(entries, [WidgetEntryPlan(date: date(27, 9), phase: .needsRefresh, showsUpdatedCaption: true)])
    }

    func testMidnightBoundaryAcrossDSTUsesLocalMidnight() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-11-01 is the fall-back day (25-hour day).
        let generated = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 20))!
        let entries = WidgetTimelinePlanner.entries(generatedAt: generated, now: generated, calendar: newYork)
        let estimate = entries.first { $0.phase == .estimate }!
        XCTAssertEqual(newYork.dateComponents([.day, .hour, .minute], from: estimate.date), DateComponents(day: 2, hour: 0, minute: 0))
    }

    func testExactly36HoursIsNeedsRefresh() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 1), at: date(28, 13), calendar: calendar), .needsRefresh)
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 1), at: date(28, 12, 59), calendar: calendar), .estimate)
    }

    func testJustUnder36HoursButTwoCalendarDaysLaterIsNeedsRefresh() {
        // 27th 23:30 -> 29th 00:00 is 24.5h but two calendar days.
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 23, 30), at: date(29, 0), calendar: calendar), .needsRefresh)
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 23, 30), at: date(28, 23, 59), calendar: calendar), .estimate)
    }

    func testPhaseAtExactMidnightIsEstimate() {
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 20), at: date(28, 0), calendar: calendar), .estimate)
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: date(27, 20), at: date(27, 23, 59), calendar: calendar), .current)
    }

    func testCaptionExactlyAtThreeHoursAndBefore() {
        XCTAssertFalse(WidgetTimelinePlanner.showsUpdatedCaption(generatedAt: date(27, 9), at: date(27, 9)))
        XCTAssertTrue(WidgetTimelinePlanner.showsUpdatedCaption(generatedAt: date(27, 9), at: date(27, 20)))
    }

    func testEntriesAfterMidnightStartAsEstimateAndDropPastBoundaries() {
        let entries = WidgetTimelinePlanner.entries(generatedAt: date(27, 20), now: date(28, 1), calendar: calendar)
        XCTAssertEqual(entries.map(\.date), [date(28, 1), date(29, 0), date(29, 8)])
        XCTAssertEqual(entries.map(\.phase), [.estimate, .needsRefresh, .needsRefresh])
        XCTAssertTrue(entries.allSatisfy(\.showsUpdatedCaption))
    }

    func testEntriesNowOnBoundaryDoesNotDuplicate() {
        let entries = WidgetTimelinePlanner.entries(generatedAt: date(27, 9), now: date(27, 12), calendar: calendar)
        XCTAssertEqual(entries.first?.date, date(27, 12))
        XCTAssertEqual(entries.filter { $0.date == date(27, 12) }.count, 1)
        XCTAssertEqual(entries.first?.showsUpdatedCaption, true)
    }

    func testEntriesAreStrictlyAscendingAndFlagEstimate() {
        let entries = WidgetTimelinePlanner.entries(generatedAt: date(27, 9), now: date(27, 9, 1), calendar: calendar)
        XCTAssertEqual(entries.map(\.date), entries.map(\.date).sorted())
        XCTAssertEqual(Set(entries.map(\.date)).count, entries.count)
        XCTAssertEqual(entries.filter { $0.phase == .estimate }.map(\.date), [date(28, 0)])
        XCTAssertEqual(entries.first?.phase, .current)
        XCTAssertEqual(entries.first?.showsUpdatedCaption, false)
    }

    func testSpringForwardDayMidnightAndPhase() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08 spring forward (23-hour day).
        let generated = newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 20))!
        let entries = WidgetTimelinePlanner.entries(generatedAt: generated, now: generated, calendar: newYork)
        let estimate = entries.first { $0.phase == .estimate }!
        XCTAssertEqual(newYork.dateComponents([.day, .hour], from: estimate.date), DateComponents(day: 9, hour: 0))
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: generated, at: newYork.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 59))!, calendar: newYork), .current)
    }

    func testFallBackLongDayStaysCurrentUntilLocalMidnight() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let generated = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!
        let lateSameDay = newYork.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 59))!
        let nextMidnight = newYork.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: generated, at: lateSameDay, calendar: newYork), .current)
        XCTAssertEqual(WidgetTimelinePlanner.phase(generatedAt: generated, at: nextMidnight, calendar: newYork), .estimate)
    }
}
