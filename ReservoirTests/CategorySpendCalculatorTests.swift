import XCTest
@testable import Reservoir

final class CategorySpendCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func entry(_ d: Date, _ amount: Decimal, _ category: String?) -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category)
    }

    func test_groupsByCategoryWithinMonthLargestFirst() {
        let entries = [
            entry(date(2026, 10, 1), 10, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 31), 15, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 5), 40, "TRANSPORTATION"),
            entry(date(2026, 9, 30), 99, "TRANSPORTATION"),
            entry(date(2026, 11, 1), 99, "TRANSPORTATION"),
        ]
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(month.total, 65)
        XCTAssertEqual(month.rows.map(\.category), ["TRANSPORTATION", "FOOD_AND_DRINK"])
        XCTAssertEqual(month.rows.last?.amount, 25)
        XCTAssertEqual(month.rows.last?.count, 2)
    }

    func test_uncategorizedSpendIsItsOwnRow() {
        let entries = [entry(date(2026, 10, 2), 5, nil), entry(date(2026, 10, 3), 7, "FOOD_AND_DRINK")]
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(month.rows.map(\.name), ["Food and drink", "Uncategorized"])
    }

    func test_emptyMonth() {
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: [], calendar: calendar)
        XCTAssertEqual(month, .init(rows: [], total: 0))
    }

    func test_displayName() {
        XCTAssertEqual(CategorySpendCalculator.displayName(for: "FOOD_AND_DRINK"), "Food and drink")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: "GENERAL_MERCHANDISE"), "General merchandise")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: "INCOME"), "Income")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: nil), "Uncategorized")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: ""), "Uncategorized")
    }
}
