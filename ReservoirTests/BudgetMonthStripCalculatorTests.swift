import XCTest
import SwiftData
@testable import Reservoir

final class BudgetMonthStripCalculatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV12.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func budget(start: Date, carries: Bool = true, amount: Decimal = 3100) -> Budget {
        let budget = Budget(monthlyAmount: amount, startDate: start, carriesAcrossMonths: carries, selectedAccountIDs: ["a"])
        context.insert(budget)
        return budget
    }

    @discardableResult
    private func spend(_ amount: Decimal, on when: Date) -> SpendTransaction {
        let transaction = SpendTransaction(
            amount: amount, date: when, merchantName: "M", type: .variable, entryMethod: .imported, plaidAccountID: "a"
        )
        context.insert(transaction)
        return transaction
    }

    private func strip(_ budget: Budget, _ transactions: [SpendTransaction], month: Date, now: Date) -> BudgetMonthStripCalculator.Strip? {
        BudgetMonthStripCalculator.strip(
            budget: budget, transactions: transactions, month: month, referenceDate: now, calendar: calendar
        )
    }

    func testDaysCarryAndFlagsForTheCurrentMonth() throws {
        // $3,100 over 31 days is a $100 base.
        let b = budget(start: date(2026, 10, 1))
        let rows = [spend(60, on: date(2026, 10, 1)), spend(150, on: date(2026, 10, 2)), spend(30, on: date(2026, 10, 4))]
        let result = try XCTUnwrap(strip(b, rows, month: date(2026, 10, 1), now: date(2026, 10, 5)))
        XCTAssertEqual(result.days.count, 31)
        XCTAssertEqual(result.days[0].carryOut, 40)
        XCTAssertEqual(result.days[1].carryIn, 40)
        XCTAssertEqual(result.days[1].carryOut, -10)
        XCTAssertTrue(result.days[1].isOverBase)
        XCTAssertTrue(result.days[1].isOver, "150 against a 140 limit")
        XCTAssertFalse(result.days[0].isOver)
        XCTAssertTrue(result.days[4].isToday)
        XCTAssertTrue(result.days[5].isFuture)
        XCTAssertEqual(result.days[5].spent, 0)
    }

    func testCarryNowMatchesTheTodayHeroCarry() throws {
        let b = budget(start: date(2026, 10, 1))
        let rows = [spend(60, on: date(2026, 10, 1)), spend(150, on: date(2026, 10, 2)), spend(30, on: date(2026, 10, 4)), spend(20, on: date(2026, 10, 5))]
        let now = date(2026, 10, 5)
        let result = try XCTUnwrap(strip(b, rows, month: now, now: now))
        let hero = try XCTUnwrap(BudgetCalculator.summary(budget: b, allTransactions: rows, referenceDate: now, calendar: calendar))
        XCTAssertEqual(result.carryNow, hero.carriedForward, "today's spend is not banked yet")
        XCTAssertEqual(result.days[4].limit, hero.limit)
    }

    func testPartialFirstMonthStartsOnTheBudgetStartDay() throws {
        let b = budget(start: date(2026, 10, 20))
        let result = try XCTUnwrap(strip(b, [], month: date(2026, 10, 1), now: date(2026, 10, 22)))
        XCTAssertEqual(result.days.first?.date, calendar.startOfDay(for: date(2026, 10, 20)))
        XCTAssertEqual(result.days.count, 12)
        XCTAssertFalse(result.hasPrevious)
    }

    func testPreviousMonthCarriesIntoTheNext() throws {
        let b = budget(start: date(2026, 9, 1), amount: 3000)  // $100/day in 30-day September
        let rows = [spend(40, on: date(2026, 9, 30))]
        let result = try XCTUnwrap(strip(b, rows, month: date(2026, 10, 1), now: date(2026, 10, 3)))
        let september = try XCTUnwrap(strip(b, rows, month: date(2026, 9, 1), now: date(2026, 10, 3)))
        XCTAssertEqual(result.days[0].carryIn, september.days.last?.carryOut)
        XCTAssertTrue(result.hasPrevious)
        XCTAssertFalse(result.hasNext)
        XCTAssertTrue(september.hasNext)
    }

    func testStartFreshZeroesCarryOnTheFirst() throws {
        let b = budget(start: date(2026, 9, 1), carries: false, amount: 3000)
        let result = try XCTUnwrap(strip(b, [], month: date(2026, 10, 1), now: date(2026, 10, 3)))
        XCTAssertEqual(result.days[0].carryIn, 0)
    }

    func testMonthsOutsideTheBudgetReturnNil() {
        let b = budget(start: date(2026, 9, 1))
        XCTAssertNil(strip(b, [], month: date(2026, 8, 1), now: date(2026, 10, 3)))
        XCTAssertNil(strip(b, [], month: date(2026, 11, 1), now: date(2026, 10, 3)))
    }

    func testBudgetStartingTodayHasOnePastlessDay() throws {
        let b = budget(start: date(2026, 10, 5))
        let result = try XCTUnwrap(strip(b, [], month: date(2026, 10, 5), now: date(2026, 10, 5)))
        XCTAssertEqual(result.days.first?.date, calendar.startOfDay(for: date(2026, 10, 5)))
        XCTAssertTrue(result.days.first?.isToday ?? false)
        XCTAssertEqual(result.carryNow, 0)
    }

    func testBudgetStartingAfterTheMonthReturnsNil() {
        let b = budget(start: date(2026, 11, 3))
        XCTAssertNil(strip(b, [], month: date(2026, 10, 1), now: date(2026, 11, 5)))
    }

    func testFutureDatedTransactionIsNotCounted() throws {
        let b = budget(start: date(2026, 10, 1))
        let rows = [spend(500, on: date(2026, 10, 20))]
        let result = try XCTUnwrap(strip(b, rows, month: date(2026, 10, 1), now: date(2026, 10, 5)))
        XCTAssertEqual(result.days[19].spent, 0)
        XCTAssertEqual(result.carryNow, 400, "four finished days of $100 base, nothing spent")
    }

    func testStartFreshCarryNowOnTheFirstIsZero() throws {
        let b = budget(start: date(2026, 9, 1), carries: false, amount: 3000)
        let rows = [spend(20, on: date(2026, 9, 30))]
        let result = try XCTUnwrap(strip(b, rows, month: date(2026, 10, 1), now: date(2026, 10, 1)))
        XCTAssertEqual(result.carryNow, 0)
        XCTAssertEqual(result.days[0].carryIn, 0)
    }

    func testSkippedMidnightDayKeepsItsSpend() throws {
        // Sao Paulo skipped midnight on 2018-11-04, so that day starts at 01:00.
        var sp = Calendar(identifier: .gregorian)
        sp.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        let b = Budget(
            monthlyAmount: 3000,
            startDate: sp.date(from: DateComponents(year: 2018, month: 10, day: 28))!,
            carriesAcrossMonths: true, selectedAccountIDs: ["a"]
        )
        context.insert(b)
        let rows = [
            spend(50, on: sp.date(from: DateComponents(year: 2018, month: 11, day: 4, hour: 15))!),
            spend(70, on: sp.date(from: DateComponents(year: 2018, month: 11, day: 5, hour: 9))!)
        ]
        let now = sp.date(from: DateComponents(year: 2018, month: 11, day: 8, hour: 12))!
        let result = try XCTUnwrap(BudgetMonthStripCalculator.strip(
            budget: b, transactions: rows, month: now, referenceDate: now, calendar: sp
        ))
        XCTAssertEqual(result.days.count, 30)
        XCTAssertEqual(result.days[3].spent, 50, "Nov 4")
        XCTAssertEqual(result.days[4].spent, 70, "Nov 5")
        let hero = try XCTUnwrap(BudgetCalculator.summary(budget: b, allTransactions: rows, referenceDate: now, calendar: sp))
        XCTAssertEqual(result.carryNow, hero.carriedForward)
    }
}
