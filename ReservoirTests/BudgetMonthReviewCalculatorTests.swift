import XCTest
import SwiftData
@testable import Reservoir

final class BudgetMonthReviewCalculatorTests: XCTestCase {

    private typealias Calc = BudgetMonthReviewCalculator

    private func makeCalendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV11.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0, in cal: Calendar? = nil) -> Date {
        (cal ?? calendar).date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }

    @discardableResult
    private func txn(
        _ amount: Decimal,
        at when: Date,
        account: String? = "acct-1",
        type: TransactionType = .variable
    ) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount, date: when, merchantName: "M", type: type, entryMethod: .imported,
            plaidAccountID: account
        )
        context.insert(transaction)
        return transaction
    }

    private func makeBudget(
        monthly: Decimal = 3100,
        start: Date,
        carries: Bool = true,
        accounts: [String] = ["acct-1"]
    ) -> Budget {
        let budget = Budget(monthlyAmount: monthly, startDate: start, carriesAcrossMonths: carries, selectedAccountIDs: accounts)
        context.insert(budget)
        return budget
    }

    private func all() throws -> [SpendTransaction] { try context.fetch(FetchDescriptor<SpendTransaction>()) }

    private func reviews(_ budget: Budget, asOf: Date, cal: Calendar? = nil) throws -> [Calc.MonthReview] {
        Calc.reviews(budget: budget, transactions: try all(), referenceDate: asOf, calendar: cal ?? calendar)
    }

    // MARK: - Ordering and window

    func testNewestFirstCompletedMonthsOnlyCurrentMonthExcluded() throws {
        let budget = makeBudget(start: date(2026, 1, 1))
        let result = try reviews(budget, asOf: date(2026, 4, 15))
        XCTAssertEqual(result.map(\.monthStart), [date(2026, 3, 1), date(2026, 2, 1), date(2026, 1, 1)])
    }

    func testReferenceOnFirstOfMonthTreatsPreviousMonthAsCompleted() throws {
        let budget = makeBudget(start: date(2026, 1, 1))
        let result = try reviews(budget, asOf: date(2026, 2, 1))
        XCTAssertEqual(result.map(\.monthStart), [date(2026, 1, 1)])
    }

    func testBudgetStartingThisMonthIsEmpty() throws {
        let budget = makeBudget(start: date(2026, 4, 1))
        XCTAssertTrue(try reviews(budget, asOf: date(2026, 4, 20)).isEmpty)
        let mid = makeBudget(start: date(2026, 4, 10))
        XCTAssertTrue(try reviews(mid, asOf: date(2026, 4, 20)).isEmpty)
    }

    func testBudgetStartingInFutureIsEmpty() throws {
        let budget = makeBudget(start: date(2026, 6, 1))
        XCTAssertTrue(try reviews(budget, asOf: date(2026, 4, 20)).isEmpty)
    }

    func testMonthsBeforeStartDateAreNotListed() throws {
        let budget = makeBudget(start: date(2026, 3, 1))
        let result = try reviews(budget, asOf: date(2026, 5, 2))
        XCTAssertEqual(result.map(\.monthStart), [date(2026, 4, 1), date(2026, 3, 1)])
    }

    // MARK: - Budgeted

    func testFullMonthBudgetedEqualsMonthlyAmountFor28And30And31DayMonths() throws {
        let budget = makeBudget(monthly: 1000, start: date(2026, 1, 1))
        let result = try reviews(budget, asOf: date(2026, 5, 1))
        XCTAssertEqual(result.count, 4)
        for review in result {
            XCTAssertEqual(review.budgeted, 1000, "\(review.monthStart)")
            XCTAssertFalse(review.isPartialStart)
            XCTAssertEqual(review.windowStart, review.monthStart)
        }
    }

    func testFebruaryLeapAndNonLeapBudgetedExactlyMonthly() throws {
        let leap = makeBudget(monthly: 2900, start: date(2024, 2, 1))
        let leapResult = try reviews(leap, asOf: date(2024, 3, 5))
        XCTAssertEqual(leapResult.first?.budgeted, 2900)
        let nonLeap = makeBudget(monthly: 2800, start: date(2025, 2, 1))
        let nonLeapResult = try reviews(nonLeap, asOf: date(2025, 3, 5))
        XCTAssertEqual(nonLeapResult.first?.budgeted, 2800)
    }

    func testPartialFirstMonthIsProratedAndFlagged() throws {
        // Jan has 31 days; start Jan 16 => 16 tracked days at 100 = 1600.
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 16))
        let result = try reviews(budget, asOf: date(2026, 3, 10))
        XCTAssertEqual(result.map(\.monthStart), [date(2026, 2, 1), date(2026, 1, 1)])
        let jan = try XCTUnwrap(result.last)
        XCTAssertTrue(jan.isPartialStart)
        XCTAssertEqual(jan.windowStart, date(2026, 1, 16))
        XCTAssertEqual(jan.budgeted, 1600)
        XCTAssertFalse(result[0].isPartialStart)
        XCTAssertEqual(result[0].budgeted, 3100)
    }

    func testStartTimeOfDayWithinFirstDayCountsThatDay() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 16, hour: 15, minute: 30))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 3)).first)
        XCTAssertEqual(jan.windowStart, date(2026, 1, 16))
        XCTAssertEqual(jan.budgeted, 1600)
    }

    func testStartOnLastDayOfMonthIsOneDayPartial() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 31))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 3)).first)
        XCTAssertTrue(jan.isPartialStart)
        XCTAssertEqual(jan.budgeted, 100)
    }

    // MARK: - Spent, delta, verdict

    func testSpentDeltaAndMonthWithNoSpend() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(40, at: date(2026, 1, 5))
        txn(60, at: date(2026, 1, 5, hour: 18))
        let result = try reviews(budget, asOf: date(2026, 3, 2))
        let feb = result[0], jan = result[1]
        XCTAssertEqual(jan.spent, 100)
        XCTAssertEqual(jan.delta, 3000)
        XCTAssertEqual(jan.deltaText, "$3,000 under")
        XCTAssertEqual(feb.spent, 0)
        XCTAssertEqual(feb.daysOver, 0)
        XCTAssertEqual(feb.delta, feb.budgeted)
        XCTAssertEqual(feb.verdict, .under)
    }

    func testOverBudgetText() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(3145, at: date(2026, 1, 10))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.delta, -45)
        XCTAssertEqual(jan.verdict, .over)
        XCTAssertEqual(jan.deltaText, "$45 over")
    }

    func testRightOnToleranceBoundaries() {
        func review(delta: Decimal) -> Calc.MonthReview {
            Calc.MonthReview(monthStart: date(2026, 1, 1), isPartialStart: false, windowStart: date(2026, 1, 1),
                             budgeted: 100, spent: 100 - delta, delta: delta, daysOver: 0, endingCarry: 0)
        }
        XCTAssertEqual(review(delta: 0).deltaText, "right on")
        XCTAssertEqual(review(delta: Decimal(string: "0.99")!).deltaText, "right on")
        XCTAssertEqual(review(delta: Decimal(string: "-0.99")!).deltaText, "right on")
        XCTAssertEqual(review(delta: 1).verdict, .under)
        XCTAssertEqual(review(delta: 1).deltaText, "$1 under")
        XCTAssertEqual(review(delta: -1).verdict, .over)
        XCTAssertEqual(review(delta: -1).deltaText, "$1 over")
    }

    func testRightOnFromCalculatedMonth() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(3100, at: date(2026, 1, 20))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.deltaText, "right on")
    }

    // MARK: - Days over

    func testDaysOverCountsOnlyDaysSpendExceedsBasePlusCarry() throws {
        // Base 100/day (31-day month). Carry mode.
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(100, at: date(2026, 1, 1))   // == limit, not over
        txn(101, at: date(2026, 1, 2))   // limit 100 + carry 0 => over by 1
        // Jan 3: carry = -1, limit 99; spend 99 -> not over
        txn(99, at: date(2026, 1, 3))
        // Jan 4: carry -1; spend 150 > 99 -> over
        txn(150, at: date(2026, 1, 4))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.daysOver, 2)
    }

    func testBankedCarryRaisesLimitSoLargeSpendIsNotOver() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        // Jan 1..4 no spend: carry 400 at Jan 5, limit 500.
        txn(450, at: date(2026, 1, 5))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.daysOver, 0)
    }

    func testZeroSpendDayNeverCountsEvenInDebt() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(5000, at: date(2026, 1, 1))  // deep debt for the rest of the month
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.daysOver, 1, "only the spending day, not the 30 zero-spend debt days")
    }

    func testDaysOverTextSingularPlural() {
        func text(_ n: Int) -> String {
            Calc.MonthReview(monthStart: date(2026, 1, 1), isPartialStart: false, windowStart: date(2026, 1, 1),
                             budgeted: 0, spent: 0, delta: 0, daysOver: n, endingCarry: 0).daysOverText
        }
        XCTAssertEqual(text(0), "0 days over")
        XCTAssertEqual(text(1), "1 day over")
        XCTAssertEqual(text(2), "2 days over")
    }

    // MARK: - Carry vs fresh

    func testCarryModeEndingCarryIsSurplusAndFreshStartIsZero() throws {
        let carry = makeBudget(monthly: 3100, start: date(2026, 1, 1), carries: true)
        let fresh = makeBudget(monthly: 3100, start: date(2026, 1, 1), carries: false)
        txn(1000, at: date(2026, 1, 10))
        let carryJan = try XCTUnwrap(try reviews(carry, asOf: date(2026, 2, 2)).first)
        let freshJan = try XCTUnwrap(try reviews(fresh, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(carryJan.endingCarry, 2100)
        XCTAssertEqual(freshJan.endingCarry, 0)
        XCTAssertEqual(freshJan.spent, carryJan.spent)
        XCTAssertEqual(freshJan.budgeted, carryJan.budgeted)
    }

    func testFreshStartResetsCarryEachMonthSoDaysOverDiffer() throws {
        // January overspend creates debt; in carry mode February's first days have a reduced limit.
        let carry = makeBudget(monthly: 3100, start: date(2026, 1, 1), carries: true)
        let fresh = makeBudget(monthly: 2800, start: date(2026, 1, 1), carries: false)
        txn(4000, at: date(2026, 1, 31))
        txn(100, at: date(2026, 2, 1))  // Feb base for carry budget is 3100/28 = 110.71
        let carryResult = try reviews(carry, asOf: date(2026, 3, 2))
        let freshResult = try reviews(fresh, asOf: date(2026, 3, 2))
        XCTAssertEqual(carryResult[0].daysOver, 1, "Feb 1 limit is base + large negative carry")
        XCTAssertEqual(freshResult[0].daysOver, 0, "reset on the 1st")
    }

    func testDebtMonthHasNegativeEndingCarry() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(3600, at: date(2026, 1, 15))
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.endingCarry, -500)
        XCTAssertEqual(jan.delta, -500)
    }

    func testEndingCarryAccumulatesAcrossMonthsInCarryMode() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(1000, at: date(2026, 1, 10))
        let result = try reviews(budget, asOf: date(2026, 3, 2))
        XCTAssertEqual(result[1].endingCarry, 2100)
        XCTAssertEqual(result[0].endingCarry, 2100 + 3100, "Feb: nothing spent, banks its whole 3100")
    }

    // MARK: - Agreement with DailyLimitCalculator.carryForward

    private func assertAgreement(
        _ budget: Budget, asOf: Date, cal: Calendar? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let cal = cal ?? calendar
        let txns = try all()
        let result = Calc.reviews(budget: budget, transactions: txns, referenceDate: asOf, calendar: cal)
        XCTAssertFalse(result.isEmpty, file: file, line: line)
        let input = BudgetCalculator.carryForwardInput(for: budget, transactions: txns, calendar: cal)
        for review in result {
            let nextFirst = cal.date(byAdding: .month, value: 1, to: review.monthStart)!
            let expected = DailyLimitCalculator.carryForward(for: input, asOf: nextFirst, calendar: cal)
            XCTAssertEqual(review.endingCarry, expected, "month \(review.monthStart)", file: file, line: line)
        }
    }

    func testEndingCarryMatchesCarryForwardInCarryModeAcrossSeveralMonths() throws {
        let budget = makeBudget(monthly: 3000, start: date(2026, 1, 9), carries: true)
        txn(123.45, at: date(2026, 1, 10))
        txn(900, at: date(2026, 2, 3))
        txn(4000, at: date(2026, 3, 20))
        txn(12.34, at: date(2026, 4, 30, hour: 23, minute: 59, second: 59))
        txn(77, at: date(2026, 5, 1))
        try assertAgreement(budget, asOf: date(2026, 6, 14))
    }

    func testEndingCarryMatchesCarryForwardInFreshStartMode() throws {
        let budget = makeBudget(monthly: 3000, start: date(2026, 1, 9), carries: false)
        txn(123.45, at: date(2026, 1, 10))
        txn(4000, at: date(2026, 3, 20))
        txn(77, at: date(2026, 5, 1))
        try assertAgreement(budget, asOf: date(2026, 6, 14))
        let result = try reviews(budget, asOf: date(2026, 6, 14))
        XCTAssertTrue(result.allSatisfy { $0.endingCarry == 0 })
    }

    func testEndingCarryMatchesCarryForwardWhenAsOfIsFirstOfMonth() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(250, at: date(2026, 1, 31))
        try assertAgreement(budget, asOf: date(2026, 2, 1))
    }

    // MARK: - Boundary transactions

    func testTransactionOnLastDayAndFirstDayLandInDifferentMonths() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 1))
        txn(10, at: date(2026, 1, 31, hour: 23, minute: 59, second: 59))
        txn(20, at: date(2026, 2, 1))                     // exactly midnight
        txn(30, at: date(2026, 2, 1, hour: 0, minute: 0, second: 1))
        let result = try reviews(budget, asOf: date(2026, 3, 2))
        XCTAssertEqual(result[1].spent, 10)
        XCTAssertEqual(result[0].spent, 50)
    }

    // MARK: - Exclusions

    func testExcludedTransactionsDoNotCount() throws {
        let budget = makeBudget(monthly: 3100, start: date(2026, 1, 10))
        txn(10, at: date(2026, 1, 12))                                 // counts
        txn(500, at: date(2026, 1, 12), type: .fixed)                  // fixed
        txn(500, at: date(2026, 1, 12), account: "other")              // unselected
        txn(500, at: date(2026, 1, 12), account: nil)                  // nil account
        txn(500, at: date(2026, 1, 9, hour: 23, minute: 59))           // before startDate
        let jan = try XCTUnwrap(try reviews(budget, asOf: date(2026, 2, 2)).first)
        XCTAssertEqual(jan.spent, 10)
        XCTAssertEqual(jan.daysOver, 0)
    }

    // MARK: - DST

    func testSaoPauloSkippedMidnightMonthAgreesWithCarryForward() throws {
        // 2018-11-04 00:00 does not exist in America/Sao_Paulo (DST starts); its start of day is 01:00.
        let cal = makeCalendar("America/Sao_Paulo")
        let budget = makeBudget(monthly: 3000, start: date(2018, 10, 20, in: cal), carries: true)
        txn(50, at: date(2018, 10, 31, hour: 12, in: cal))
        txn(80, at: date(2018, 11, 3, hour: 23, minute: 30, in: cal))
        txn(120, at: date(2018, 11, 4, hour: 9, in: cal))
        txn(60, at: date(2018, 11, 5, hour: 9, in: cal))
        let asOf = date(2018, 12, 10, in: cal)
        let result = try reviews(budget, asOf: asOf, cal: cal)
        XCTAssertEqual(result.map(\.monthStart), [date(2018, 11, 1, in: cal), date(2018, 10, 1, in: cal)])
        let nov = result[0]
        XCTAssertEqual(nov.budgeted, 3000)
        XCTAssertEqual(nov.spent, 260)
        XCTAssertEqual(result[1].spent, 50)
        XCTAssertLessThan(abs(result[1].budgeted - 3000 * 12 / 31), Decimal(string: "0.000001")!)
        try assertAgreement(budget, asOf: asOf, cal: cal)
    }

    func testSaoPauloBudgetStartingOnSkippedMidnightDay() throws {
        let cal = makeCalendar("America/Sao_Paulo")
        let budget = makeBudget(monthly: 3000, start: date(2018, 11, 4, hour: 1, in: cal), carries: true)
        txn(100, at: date(2018, 11, 4, hour: 9, in: cal))
        let result = try reviews(budget, asOf: date(2018, 12, 3, in: cal), cal: cal)
        let nov = try XCTUnwrap(result.first)
        XCTAssertTrue(nov.isPartialStart)
        XCTAssertEqual(nov.budgeted, 3000 * 27 / 30)
        XCTAssertEqual(nov.spent, 100)
        try assertAgreement(budget, asOf: date(2018, 12, 3, in: cal), cal: cal)
    }

    func testNewYorkMarchSpringForwardMonth() throws {
        let cal = makeCalendar("America/New_York")
        let budget = makeBudget(monthly: 3100, start: date(2026, 2, 1, in: cal), carries: true)
        txn(100, at: date(2026, 3, 8, hour: 1, minute: 30, in: cal))   // before the 02:00 jump
        txn(100, at: date(2026, 3, 8, hour: 12, in: cal))
        txn(40, at: date(2026, 3, 31, hour: 23, minute: 59, in: cal))
        let result = try reviews(budget, asOf: date(2026, 4, 10, in: cal), cal: cal)
        XCTAssertEqual(result.map(\.monthStart), [date(2026, 3, 1, in: cal), date(2026, 2, 1, in: cal)])
        let march = result[0]
        XCTAssertEqual(march.budgeted, 3100)
        XCTAssertEqual(march.spent, 240)
        try assertAgreement(budget, asOf: date(2026, 4, 10, in: cal), cal: cal)
    }

    func testNewYorkNovemberFallBackMonth() throws {
        let cal = makeCalendar("America/New_York")
        let budget = makeBudget(monthly: 3000, start: date(2026, 11, 1, in: cal), carries: false)
        txn(25, at: date(2026, 11, 1, hour: 1, minute: 30, in: cal))
        let nov = try XCTUnwrap(try reviews(budget, asOf: date(2026, 12, 2, in: cal), cal: cal).first)
        XCTAssertEqual(nov.budgeted, 3000)
        XCTAssertEqual(nov.spent, 25)
    }

    // MARK: - screen()

    private func screen(_ budget: Budget, backfill: Bool = true, asOf: Date) throws -> Calc.Screen {
        Calc.screen(budget: budget, transactions: try all(), isAccountBackfillComplete: backfill,
                    referenceDate: asOf, calendar: calendar)
    }

    func testScreenSyncingWhenBackfillIncomplete() throws {
        let budget = makeBudget(start: date(2026, 1, 1))
        XCTAssertEqual(try screen(budget, backfill: false, asOf: date(2026, 4, 1)), .status(.syncing))
    }

    func testScreenSyncingTakesPrecedenceOverChooseAccounts() throws {
        let budget = makeBudget(start: date(2026, 1, 1), accounts: [])
        XCTAssertEqual(try screen(budget, backfill: false, asOf: date(2026, 4, 1)), .status(.syncing))
    }

    func testScreenChooseAccountsWhenNoSelection() throws {
        let budget = makeBudget(start: date(2026, 1, 1), accounts: [])
        XCTAssertEqual(try screen(budget, asOf: date(2026, 4, 1)), .status(.chooseAccounts))
    }

    func testScreenEmptyWhenNoCompletedMonths() throws {
        let budget = makeBudget(start: date(2026, 4, 1))
        XCTAssertEqual(try screen(budget, asOf: date(2026, 4, 20)), .empty)
        XCTAssertEqual(Calc.emptyMessage, "No completed months yet")
    }

    func testScreenMonthsWhenActiveAndCompleted() throws {
        let budget = makeBudget(start: date(2026, 1, 1))
        let expected = try reviews(budget, asOf: date(2026, 3, 5))
        XCTAssertEqual(try screen(budget, asOf: date(2026, 3, 5)), .months(expected))
        XCTAssertEqual(expected.count, 2)
    }
}
