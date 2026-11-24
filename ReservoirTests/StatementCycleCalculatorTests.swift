import XCTest
@testable import Reservoir

final class StatementCycleCalculatorTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    private func cycles(closing: Int, due: Int? = nil, asOf: Date, count: Int = 3) -> [StatementCycleCalculator.Cycle] {
        StatementCycleCalculator.cycles(closingDay: closing, dueDay: due, asOf: asOf, count: count, calendar: calendar)
    }

    func testOpenCycleRunsFromTheDayAfterThePreviousClosingToTheNextClosing() {
        let result = cycles(closing: 25, asOf: day(2026, 11, 22))
        XCTAssertEqual(result[0].start, day(2026, 10, 26))
        XCTAssertEqual(result[0].closing, day(2026, 11, 25))
        XCTAssertTrue(result[0].isOpen)
        XCTAssertEqual(result[1].closing, day(2026, 10, 25))
        XCTAssertFalse(result[1].isOpen)
        XCTAssertEqual(result[1].start, day(2026, 9, 26))
    }

    func testAfterTheClosingDayTheOpenCycleIsTheNextMonths() {
        let result = cycles(closing: 25, asOf: day(2026, 11, 28))
        XCTAssertEqual(result[0].closing, day(2026, 12, 25))
        XCTAssertEqual(result[0].start, day(2026, 11, 26))
        XCTAssertEqual(result[1].closing, day(2026, 11, 25))
    }

    func testOnTheClosingDayTheCycleIsStillOpen() {
        let result = cycles(closing: 25, asOf: day(2026, 11, 25, hour: 18))
        XCTAssertEqual(result[0].closing, day(2026, 11, 25))
        XCTAssertTrue(result[0].isOpen)
    }

    func testShortMonthsClampTheClosingDay() {
        let result = cycles(closing: 31, asOf: day(2027, 2, 10))
        XCTAssertEqual(result[0].closing, day(2027, 2, 28))
        XCTAssertEqual(result[0].start, day(2027, 2, 1))
        XCTAssertEqual(result[1].closing, day(2027, 1, 31))
    }

    func testDueDayBeforeTheClosingDayFallsInTheNextMonth() {
        let result = cycles(closing: 25, due: 16, asOf: day(2026, 11, 22))
        XCTAssertEqual(result[0].dueDate, day(2026, 12, 16))
        XCTAssertEqual(result[1].dueDate, day(2026, 11, 16))
    }

    func testDueDayAfterTheClosingDayFallsInTheSameMonth() {
        let result = cycles(closing: 5, due: 22, asOf: day(2026, 11, 22))
        XCTAssertEqual(result[0].closing, day(2026, 12, 5))
        XCTAssertEqual(result[0].dueDate, day(2026, 12, 22))
        XCTAssertEqual(result[1].closing, day(2026, 11, 5))
        XCTAssertEqual(result[1].dueDate, day(2026, 11, 22))
    }

    func testNoDueDayMeansNoDueDates() {
        XCTAssertNil(cycles(closing: 25, asOf: day(2026, 11, 22))[0].dueDate)
    }

    func testTotalCountsTheCardsChargesIncludingBothEndDays() {
        let cycle = cycles(closing: 25, asOf: day(2026, 11, 22))[0]
        func txn(_ amount: Decimal, _ date: Date, account: String? = "card", type: TransactionType = .variable) -> SpendTransaction {
            SpendTransaction(amount: amount, date: date, merchantName: "m", type: type, entryMethod: .imported, plaidAccountID: account)
        }
        let transactions = [
            txn(10, day(2026, 10, 25, hour: 23)),         // before the cycle
            txn(20, day(2026, 10, 26)),                    // first day
            txn(30, day(2026, 11, 25, hour: 23)),          // closing day, late
            txn(40, day(2026, 11, 26)),                    // after
            txn(50, day(2026, 11, 1), account: "other"),   // different account
            txn(5, day(2026, 11, 10), type: .fixed)        // fixed charges are on the bill too
        ]
        XCTAssertEqual(StatementCycleCalculator.total(of: cycle, accountID: "card", in: transactions, calendar: calendar), 55)
    }

    func testTransactionsInCycleAreThisCardsNewestFirst() {
        let cycle = cycles(closing: 25, asOf: day(2026, 11, 22))[0]
        func txn(_ name: String, _ date: Date, account: String = "card") -> SpendTransaction {
            SpendTransaction(amount: 1, date: date, merchantName: name, type: .variable, entryMethod: .imported, plaidAccountID: account)
        }
        let transactions = [
            txn("old", day(2026, 10, 25)), txn("a", day(2026, 10, 27)), txn("c", day(2026, 11, 20)),
            txn("other", day(2026, 11, 1), account: "x"), txn("b", day(2026, 11, 2))
        ]
        let result = StatementCycleCalculator.transactions(in: cycle, accountID: "card", from: transactions, calendar: calendar)
        XCTAssertEqual(result.map(\.merchantName), ["c", "b", "a"])
    }

    func testSortAndGroupCharges() {
        func txn(_ name: String, _ amount: Decimal, _ date: Date, _ category: String?) -> SpendTransaction {
            SpendTransaction(amount: amount, date: date, merchantName: name, type: .variable, entryMethod: .imported, plaidAccountID: "card", category: category)
        }
        let all = [
            txn("a", 10, day(2026, 11, 1), "FOOD_AND_DRINK"),
            txn("b", 50, day(2026, 11, 3), "TRAVEL"),
            txn("c", 30, day(2026, 11, 5), "FOOD_AND_DRINK"),
            txn("d", 5, day(2026, 11, 4), nil)
        ]
        XCTAssertEqual(StatementCycleCalculator.sorted(all, by: .amount).map(\.merchantName), ["b", "c", "a", "d"])
        XCTAssertEqual(StatementCycleCalculator.sorted(all, by: .date).map(\.merchantName), ["c", "d", "b", "a"])
        let byAmount = StatementCycleCalculator.grouped(all, by: .amount)
        XCTAssertEqual(byAmount.map(\.name), ["Travel", "Food and drink", "Uncategorized"])
        XCTAssertEqual(byAmount[1].charges.map(\.merchantName), ["c", "a"])
        let byDate = StatementCycleCalculator.grouped(all, by: .date)
        XCTAssertEqual(byDate.map(\.name), ["Food and drink", "Uncategorized", "Travel"])
    }

    func testBillDueIsTheNewestClosedStatementNotYetPastItsDueDate() {
        let asOf = day(2026, 11, 22)
        let result = cycles(closing: 25, due: 16, asOf: asOf, count: 4)
        // Oct 25 statement is due Nov 16 (past); Nov 25 has not closed. Nothing is waiting.
        XCTAssertNil(StatementCycleCalculator.billDue(in: result, asOf: asOf, calendar: calendar))
        let later = day(2026, 11, 28)
        let afterClose = cycles(closing: 25, due: 16, asOf: later, count: 4)
        XCTAssertEqual(StatementCycleCalculator.billDue(in: afterClose, asOf: later, calendar: calendar)?.closing, day(2026, 11, 25))
    }
}
