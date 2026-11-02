import XCTest
@testable import Reservoir

final class TransactionsScreenCalculatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 9))!
    }

    private func day(_ offset: Int, hour: Int = 9) -> Date {
        let base = calendar.date(byAdding: .day, value: offset, to: today)!
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }

    // MARK: - filtered

    func testFilteredAllReturnsEverything() {
        let variableTx = SpendTransaction(amount: 10, date: today, merchantName: "A", type: .variable, entryMethod: .manual)
        let fixedTx = SpendTransaction(amount: 20, date: today, merchantName: "B", type: .fixed, entryMethod: .manual)
        let result = TransactionsScreenCalculator.filtered([variableTx, fixedTx], by: .all)
        XCTAssertEqual(result.count, 2)
    }

    func testFilteredVariableExcludesFixed() {
        let variableTx = SpendTransaction(amount: 10, date: today, merchantName: "A", type: .variable, entryMethod: .manual)
        let fixedTx = SpendTransaction(amount: 20, date: today, merchantName: "B", type: .fixed, entryMethod: .manual)
        let result = TransactionsScreenCalculator.filtered([variableTx, fixedTx], by: .variable)
        XCTAssertEqual(result, [variableTx])
    }

    func testFilteredFixedExcludesVariable() {
        let variableTx = SpendTransaction(amount: 10, date: today, merchantName: "A", type: .variable, entryMethod: .manual)
        let fixedTx = SpendTransaction(amount: 20, date: today, merchantName: "B", type: .fixed, entryMethod: .manual)
        let result = TransactionsScreenCalculator.filtered([variableTx, fixedTx], by: .fixed)
        XCTAssertEqual(result, [fixedTx])
    }

    // MARK: - groupedByDay

    func testGroupedByDaySeparatesDistinctDays() {
        let tx1 = SpendTransaction(amount: 10, date: day(0), merchantName: "A", type: .variable, entryMethod: .manual)
        let tx2 = SpendTransaction(amount: 20, date: day(-1), merchantName: "B", type: .variable, entryMethod: .manual)

        let sections = TransactionsScreenCalculator.groupedByDay([tx1, tx2], calendar: calendar)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].transactions, [tx1])
        XCTAssertEqual(sections[1].transactions, [tx2])
    }

    func testGroupedByDayCombinesSameDayTransactions() {
        let tx1 = SpendTransaction(amount: 10, date: day(0, hour: 9), merchantName: "A", type: .variable, entryMethod: .manual)
        let tx2 = SpendTransaction(amount: 20, date: day(0, hour: 18), merchantName: "B", type: .variable, entryMethod: .manual)

        let sections = TransactionsScreenCalculator.groupedByDay([tx1, tx2], calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].transactions, [tx1, tx2])
    }

    func testGroupedByDayEmptyInputReturnsEmpty() {
        let sections = TransactionsScreenCalculator.groupedByDay([], calendar: calendar)
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - sectionTitle

    func testSectionTitleForTodayIsToday() {
        let title = TransactionsScreenCalculator.sectionTitle(
            for: calendar.startOfDay(for: today), referenceDate: today, calendar: calendar
        )
        XCTAssertEqual(title, "Today")
    }

    func testSectionTitleForYesterdayIsYesterday() {
        let title = TransactionsScreenCalculator.sectionTitle(
            for: calendar.startOfDay(for: day(-1)), referenceDate: today, calendar: calendar
        )
        XCTAssertEqual(title, "Yesterday")
    }

    func testSectionTitleForOlderDayIsFullDate() {
        let title = TransactionsScreenCalculator.sectionTitle(
            for: calendar.startOfDay(for: day(-5)), referenceDate: today, calendar: calendar
        )
        XCTAssertNotEqual(title, "Today")
        XCTAssertNotEqual(title, "Yesterday")
        XCTAssertFalse(title.isEmpty)
    }

    // MARK: - emptyStateKind (reservoir-xle)

    func test_emptyStateKind_importingWinsOverPending() {
        XCTAssertEqual(TransactionsScreenCalculator.emptyStateKind(isInitialImport: true, isInitialDataPending: true), .importing)
        XCTAssertEqual(TransactionsScreenCalculator.emptyStateKind(isInitialImport: true, isInitialDataPending: false), .importing)
    }

    func test_emptyStateKind_pendingWhenNotImporting() {
        XCTAssertEqual(TransactionsScreenCalculator.emptyStateKind(isInitialImport: false, isInitialDataPending: true), .stillFetching)
    }

    func test_emptyStateKind_noneWhenNothingInFlight() {
        XCTAssertEqual(TransactionsScreenCalculator.emptyStateKind(isInitialImport: false, isInitialDataPending: false), .none)
    }

    // MARK: - Categories (reservoir-473)

    private func categorized(_ merchant: String, _ category: String?, detailed: String? = nil, offset: Int = 0, amount: Decimal = 10) -> SpendTransaction {
        SpendTransaction(
            amount: amount, date: day(offset), merchantName: merchant, type: .variable, entryMethod: .imported,
            category: category, categoryDetailed: detailed
        )
    }

    func testCategoryFilterNarrowsByPrimaryOrUncategorized() {
        let food = categorized("Cafe", "FOOD_AND_DRINK")
        let travel = categorized("Hotel", "TRAVEL")
        let none = categorized("Cash", nil)
        let all = [food, travel, none]
        XCTAssertEqual(TransactionsScreenCalculator.filtered(all, by: .all, category: .all).count, 3)
        XCTAssertEqual(TransactionsScreenCalculator.filtered(all, by: .all, category: .category("TRAVEL")), [travel])
        XCTAssertEqual(TransactionsScreenCalculator.filtered(all, by: .all, category: .uncategorized), [none])
    }

    func testCategoryFilterComposesWithTypeFilter() {
        let variable = categorized("Cafe", "FOOD_AND_DRINK")
        let fixed = SpendTransaction(amount: 1, date: today, merchantName: "Gym", type: .fixed, entryMethod: .imported, category: "FOOD_AND_DRINK")
        XCTAssertEqual(TransactionsScreenCalculator.filtered([variable, fixed], by: .fixed, category: .category("FOOD_AND_DRINK")), [fixed])
    }

    func testCategoryChoicesAreEmptyWhenNothingIsCategorized() {
        XCTAssertTrue(TransactionsScreenCalculator.categoryChoices([categorized("Cash", nil)]).isEmpty)
        XCTAssertTrue(TransactionsScreenCalculator.categoryChoices([]).isEmpty)
    }

    func testCategoryChoicesAreSortedByNameWithUncategorizedLast() {
        let choices = TransactionsScreenCalculator.categoryChoices([
            categorized("a", "TRAVEL"), categorized("b", "FOOD_AND_DRINK"), categorized("c", nil), categorized("d", "TRAVEL"),
        ])
        XCTAssertEqual(choices, [.all, .category("FOOD_AND_DRINK"), .category("TRAVEL"), .uncategorized])
        XCTAssertEqual(choices.map(\.title), ["All categories", "Food and drink", "Travel", "Uncategorized"])
    }

    func testChargesFilterByCategoryDetailedAndMonthNewestFirst() {
        let interval = calendar.dateInterval(of: .month, for: today)!
        let old = categorized("Old", "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_COFFEE", offset: -1)
        let new = categorized("New", "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_COFFEE", offset: 0)
        let other = categorized("Other", "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_RESTAURANT", offset: 1)
        let lastMonth = categorized("Last", "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_COFFEE", offset: -40)
        let travel = categorized("Hotel", "TRAVEL", offset: 0)
        let all = [old, other, lastMonth, travel, new]
        XCTAssertEqual(TransactionsScreenCalculator.charges(all, category: "FOOD_AND_DRINK", in: interval).map(\.merchantName), ["Other", "New", "Old"])
        XCTAssertEqual(
            TransactionsScreenCalculator.charges(all, category: "FOOD_AND_DRINK", detailed: .some("FOOD_AND_DRINK_COFFEE"), in: interval).map(\.merchantName),
            ["New", "Old"]
        )
    }

    func testChargesWithNilDetailedMatchOnlyUnlabeled() {
        let interval = calendar.dateInterval(of: .month, for: today)!
        let unlabeled = categorized("Plain", "FOOD_AND_DRINK", detailed: nil)
        let labeled = categorized("Coffee", "FOOD_AND_DRINK", detailed: "FOOD_AND_DRINK_COFFEE")
        XCTAssertEqual(TransactionsScreenCalculator.charges([unlabeled, labeled], category: "FOOD_AND_DRINK", detailed: .some(nil), in: interval), [unlabeled])
    }
}
