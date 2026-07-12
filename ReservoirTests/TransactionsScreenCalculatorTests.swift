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
}
