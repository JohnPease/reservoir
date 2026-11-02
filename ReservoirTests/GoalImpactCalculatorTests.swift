import XCTest
@testable import Reservoir

final class GoalImpactCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func entry(_ d: Date, _ amount: Decimal, _ category: String?) -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category)
    }

    /// Food $400 and Entertainment $100 a month for Jul-Sep; rent $1,500 (never suggested).
    private var history: [CategorySpendCalculator.Entry] {
        (7...9).flatMap { month in [
            entry(date(2026, month, 5), 400, "FOOD_AND_DRINK"),
            entry(date(2026, month, 6), 100, "ENTERTAINMENT"),
            entry(date(2026, month, 1), 1500, "RENT_AND_UTILITIES"),
        ] }
    }

    func test_picksBiggestDiscretionaryCategoryAndScalesByDailyBase() throws {
        // Cut 25% of $400 = $100/month = ~$3.2854/day. 100 days left, dailyBase $20 => 100*3.2854/20 = 16.4 => 16 days.
        let impact = try XCTUnwrap(GoalImpactCalculator.impact(
            entries: history, dailyBase: 20, targetDate: date(2027, 1, 18), referenceDate: date(2026, 10, 10), calendar: calendar
        ))
        XCTAssertEqual(impact.category, "FOOD_AND_DRINK")
        XCTAssertEqual(impact.monthlyAverage, 400)
        XCTAssertEqual(impact.monthlySaving, 100)
        XCTAssertEqual(impact.daysSooner, 16)
        XCTAssertEqual(impact.text, "Cutting a quarter of Food and drink (about $100 a month) would finish this goal roughly 16 days sooner.")
    }

    func test_neverSuggestsRentOrOtherFixedCategories() {
        let rentOnly = (7...9).map { entry(date(2026, $0, 1), 1500, "RENT_AND_UTILITIES") }
        XCTAssertNil(GoalImpactCalculator.impact(entries: rentOnly, dailyBase: 20, targetDate: date(2027, 1, 18), referenceDate: date(2026, 10, 10), calendar: calendar))
    }

    func test_needsTwoEarlierMonths() {
        let oneMonth = [entry(date(2026, 9, 5), 400, "FOOD_AND_DRINK")]
        XCTAssertNil(GoalImpactCalculator.impact(entries: oneMonth, dailyBase: 20, targetDate: date(2027, 1, 18), referenceDate: date(2026, 10, 10), calendar: calendar))
    }

    func test_currentMonthIsNotAveraged() throws {
        var entries = history
        entries.append(entry(date(2026, 10, 5), 5000, "TRAVEL"))
        let impact = try XCTUnwrap(GoalImpactCalculator.impact(entries: entries, dailyBase: 20, targetDate: date(2027, 1, 18), referenceDate: date(2026, 10, 10), calendar: calendar))
        XCTAssertEqual(impact.category, "FOOD_AND_DRINK")
    }

    func test_nilWhenGoalIsAlmostHereOrCutMovesLessThanADay() {
        XCTAssertNil(GoalImpactCalculator.impact(entries: history, dailyBase: 20, targetDate: date(2026, 10, 14), referenceDate: date(2026, 10, 10), calendar: calendar))
        XCTAssertNil(GoalImpactCalculator.impact(entries: history, dailyBase: 5000, targetDate: date(2027, 1, 18), referenceDate: date(2026, 10, 10), calendar: calendar))
        XCTAssertNil(GoalImpactCalculator.impact(entries: history, dailyBase: 0, targetDate: date(2027, 1, 18), referenceDate: date(2026, 10, 10), calendar: calendar))
    }
}
