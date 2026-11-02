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

    // MARK: - Comparison and history (reservoir-hnt)

    func test_completedMonthComparesWithWholePriorMonth() {
        let entries = [
            entry(date(2026, 9, 29), 30, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 2), 50, "FOOD_AND_DRINK"),
        ]
        let month = CategorySpendCalculator.month(
            containing: date(2026, 10, 15), entries: entries, now: date(2026, 11, 3), calendar: calendar
        )
        XCTAssertFalse(month.comparesPartialMonth)
        XCTAssertEqual(month.rows.first?.previousAmount, 30)
        XCTAssertEqual(month.rows.first?.change, 20)
        XCTAssertEqual(month.previousTotal, 30)
    }

    func test_currentMonthComparesWithSameDaysOfPriorMonth() {
        let entries = [
            entry(date(2026, 9, 3), 10, "FOOD_AND_DRINK"),
            entry(date(2026, 9, 20), 100, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 4), 25, "FOOD_AND_DRINK"),
        ]
        let month = CategorySpendCalculator.month(
            containing: date(2026, 10, 10), entries: entries, now: date(2026, 10, 5), calendar: calendar
        )
        XCTAssertTrue(month.comparesPartialMonth)
        XCTAssertEqual(month.rows.first?.previousAmount, 10, "only Sept 1-5 counts")
        XCTAssertEqual(month.rows.first?.change, 15)
    }

    func test_categoryOnlyInPriorMonthStillGetsARow() {
        let entries = [entry(date(2026, 9, 10), 40, "TRAVEL"), entry(date(2026, 10, 2), 5, "FOOD_AND_DRINK")]
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: entries, calendar: calendar)
        let travel = month.rows.first { $0.category == "TRAVEL" }
        XCTAssertEqual(travel?.amount, 0)
        XCTAssertEqual(travel?.count, 0)
        XCTAssertEqual(travel?.change, -40)
        XCTAssertEqual(month.rows.first?.category, "FOOD_AND_DRINK")
    }

    func test_historyListsSixMonthsOldestFirstWithZeros() {
        let entries = [
            entry(date(2026, 10, 2), 5, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 9), 7, "FOOD_AND_DRINK"),
            entry(date(2026, 7, 9), 20, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 9), 99, "TRAVEL"),
            entry(date(2026, 4, 30), 99, "FOOD_AND_DRINK"),
        ]
        let history = CategorySpendCalculator.history(
            for: "FOOD_AND_DRINK", months: 6, endingAt: date(2026, 10, 15), entries: entries, calendar: calendar
        )
        XCTAssertEqual(history.map(\.amount), [0, 0, 20, 0, 0, 12])
        XCTAssertEqual(history.first?.monthStart, date(2026, 5, 1))
        XCTAssertEqual(history.last?.monthStart, date(2026, 10, 1))
    }

    func test_historyForUncategorizedUsesNilCategory() {
        let entries = [entry(date(2026, 10, 2), 5, nil), entry(date(2026, 10, 3), 8, "TRAVEL")]
        let history = CategorySpendCalculator.history(for: nil, months: 1, endingAt: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(history.map(\.amount), [5])
    }

    // MARK: - Detailed categories (reservoir-e1y)

    private func detailed(_ d: Date, _ amount: Decimal, _ detail: String?, category: String = "FOOD_AND_DRINK") -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category, categoryDetailed: detail)
    }

    func test_detailSplitsCategoryByDetailedLabelWithComparison() {
        let entries = [
            detailed(date(2026, 10, 2), 30, "FOOD_AND_DRINK_RESTAURANT"),
            detailed(date(2026, 10, 9), 20, "FOOD_AND_DRINK_RESTAURANT"),
            detailed(date(2026, 10, 3), 12, "FOOD_AND_DRINK_COFFEE"),
            detailed(date(2026, 9, 3), 8, "FOOD_AND_DRINK_COFFEE"),
            detailed(date(2026, 9, 4), 15, "FOOD_AND_DRINK_GROCERIES"),
            detailed(date(2026, 10, 4), 99, "TRANSPORTATION_TAXIS", category: "TRANSPORTATION"),
        ]
        let rows = CategorySpendCalculator.detail(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(rows.map(\.name), ["Restaurant", "Coffee", "Groceries"])
        XCTAssertEqual(rows.map(\.amount), [50, 12, 0])
        XCTAssertEqual(rows[1].change, 4)
        XCTAssertEqual(rows[2].change, -15, "a label with spend only last month still gets a row")
    }

    func test_detailLabelMissingIsOther() {
        let entries = [detailed(date(2026, 10, 2), 5, nil)]
        let rows = CategorySpendCalculator.detail(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(rows.map(\.name), ["Other"])
    }

    func test_displayNameForDetailedDropsThePrimaryPrefix() {
        XCTAssertEqual(CategorySpendCalculator.displayName(forDetailed: "FOOD_AND_DRINK_FAST_FOOD", in: "FOOD_AND_DRINK"), "Fast food")
        XCTAssertEqual(CategorySpendCalculator.displayName(forDetailed: "OTHER_THING", in: "FOOD_AND_DRINK"), "Other thing")
        XCTAssertEqual(CategorySpendCalculator.displayName(forDetailed: nil, in: "FOOD_AND_DRINK"), "Other")
    }

    // MARK: - Unusual months (reservoir-qj2)

    /// Entertainment: $50 in each of Jun-Sep, then `current` in October. Food: steady $100.
    private func calloutEntries(entertainmentThisMonth current: Decimal) -> [CategorySpendCalculator.Entry] {
        var entries: [CategorySpendCalculator.Entry] = []
        for month in 6...9 {
            entries.append(entry(date(2026, month, 5), 50, "ENTERTAINMENT"))
            entries.append(entry(date(2026, month, 6), 100, "FOOD_AND_DRINK"))
        }
        entries.append(entry(date(2026, 10, 5), current, "ENTERTAINMENT"))
        entries.append(entry(date(2026, 10, 6), 100, "FOOD_AND_DRINK"))
        return entries
    }

    func test_calloutFiresWhenWellAboveUsual() {
        let callouts = CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 130), now: date(2026, 11, 2), calendar: calendar
        )
        XCTAssertEqual(callouts.count, 1)
        XCTAssertEqual(callouts.first?.category, "ENTERTAINMENT")
        XCTAssertEqual(callouts.first?.usual, 50)
        XCTAssertEqual(callouts.first?.text, "Entertainment was 2.6× its usual")
        XCTAssertEqual(callouts.first?.detailText, "$130 vs about $50 a month")
    }

    func test_calloutForMonthInProgressSaysSoFar() {
        let callouts = CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 130), now: date(2026, 10, 20), calendar: calendar
        )
        XCTAssertEqual(callouts.first?.text, "Entertainment is already 2.6× its usual")
        XCTAssertEqual(callouts.first?.detailText, "$130 so far vs about $50 a month")
    }

    func test_calloutNeedsRatioAndDollarExcess() {
        // 1.4x usual: under the ratio.
        XCTAssertTrue(CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 70), calendar: calendar
        ).isEmpty)
        // 1.5x of $50 is only $25 over... exactly at the threshold fires; $74 (+$24) does not.
        XCTAssertTrue(CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 74), calendar: calendar
        ).isEmpty)
        XCTAssertEqual(CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 75), calendar: calendar
        ).count, 1)
    }

    func test_calloutIgnoresSmallUsualAmounts() {
        var entries = (6...9).map { entry(date(2026, $0, 5), 10, "TRAVEL") }
        entries.append(entry(date(2026, 10, 5), 90, "TRAVEL"))
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar).isEmpty,
                      "a $10 usual is too small to call out")
    }

    func test_calloutNeedsTwoEarlierMonthsOfData() {
        let entries = [entry(date(2026, 9, 5), 50, "ENTERTAINMENT"), entry(date(2026, 10, 5), 500, "ENTERTAINMENT")]
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar).isEmpty)
    }

    func test_calloutDoesNotCountMonthsBeforeTheFirstData() {
        // Data starts in August: usual is Aug-Sep = 60, not diluted by empty months before it.
        let entries = [
            entry(date(2026, 8, 5), 60, "ENTERTAINMENT"),
            entry(date(2026, 9, 5), 60, "ENTERTAINMENT"),
            entry(date(2026, 10, 5), 100, "ENTERTAINMENT"),
        ]
        let callouts = CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(callouts.first?.usual, 60)
    }

    func test_calloutIgnoresUncategorized() {
        var entries = (6...9).map { entry(date(2026, $0, 5), 50, nil) }
        entries.append(entry(date(2026, 10, 5), 500, nil))
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar).isEmpty)
    }
}
