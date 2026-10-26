import XCTest
@testable import Reservoir

final class BudgetValidatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private let today = Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 10, day: 26))!

    private func validate(
        amount: Decimal = 1000,
        accounts: Set<String> = ["a"],
        start: Date,
        earliest: Date? = nil
    ) -> BudgetValidator.ValidationResult {
        BudgetValidator.validate(
            monthlyAmount: amount, selectedAccountIDs: accounts, startDate: start,
            earliestImportedDate: earliest, referenceDate: today, calendar: calendar
        )
    }

    func testValidInput() {
        XCTAssertTrue(validate(start: date(2026, 10, 1)).isValid)
    }

    func testAmountMustBePositive() {
        XCTAssertEqual(validate(amount: 0, start: date(2026, 10, 1)).amountError, "Enter a monthly amount greater than $0.")
        XCTAssertEqual(validate(amount: -5, start: date(2026, 10, 1)).amountError, "Enter a monthly amount greater than $0.")
    }

    func testAmountIsCappedAtOneMillion() {
        let message = "Enter an amount of $1,000,000 or less."
        XCTAssertNil(validate(amount: 1_000_000, start: date(2026, 10, 1)).amountError)
        XCTAssertTrue(validate(amount: 1_000_000, start: date(2026, 10, 1)).isValid)
        XCTAssertEqual(validate(amount: Decimal(string: "1000000.01")!, start: date(2026, 10, 1)).amountError, message)
        XCTAssertFalse(validate(amount: Decimal(string: "1000000.01")!, start: date(2026, 10, 1)).isValid)
        XCTAssertEqual(validate(amount: 5_000_000, start: date(2026, 10, 1)).amountError, message)
        XCTAssertNil(validate(amount: Decimal(string: "999999.99")!, start: date(2026, 10, 1)).amountError)
    }

    func testNeedsAtLeastOneAccount() {
        let result = validate(accounts: [], start: date(2026, 10, 1))
        XCTAssertEqual(result.accountsError, "Choose at least one account.")
        XCTAssertFalse(result.isValid)
    }

    func testStartDateCannotBeInTheFuture() {
        XCTAssertEqual(validate(start: date(2026, 10, 27)).startDateError, "Start date can't be in the future.")
        XCTAssertNil(validate(start: date(2026, 10, 26)).startDateError, "today is allowed")
    }

    func testFloorIsSevenThirtyDaysBackWithoutImportedHistory() {
        let floor = BudgetValidator.startDateFloor(earliestImportedDate: nil, referenceDate: today, calendar: calendar)
        XCTAssertEqual(floor, calendar.date(byAdding: .day, value: -730, to: today))
        XCTAssertNil(validate(start: floor).startDateError)
        XCTAssertNotNil(validate(start: calendar.date(byAdding: .day, value: -1, to: floor)!).startDateError)
    }

    func testFloorIsLaterOfHistoryCapAndEarliestImport() {
        let recent = date(2026, 6, 15)
        XCTAssertEqual(BudgetValidator.startDateFloor(earliestImportedDate: recent, referenceDate: today, calendar: calendar), recent)
        let ancient = date(2020, 1, 1)
        XCTAssertEqual(
            BudgetValidator.startDateFloor(earliestImportedDate: ancient, referenceDate: today, calendar: calendar),
            calendar.date(byAdding: .day, value: -730, to: today)
        )
    }

    func testStartBeforeEarliestImportIsRejected() {
        let result = validate(start: date(2026, 6, 14), earliest: date(2026, 6, 15))
        XCTAssertNotNil(result.startDateError)
        XCTAssertTrue(result.startDateError!.hasPrefix("Start date can't be before"))
        XCTAssertNil(validate(start: date(2026, 6, 15), earliest: date(2026, 6, 15)).startDateError)
    }

    func testDefaultStartDateIsFirstOfCurrentMonth() {
        XCTAssertEqual(BudgetValidator.defaultStartDate(referenceDate: today, calendar: calendar), date(2026, 10, 1))
    }

    func testEarliestImportedDateUsesOnlySelectedAccountsAndIgnoresManual() throws {
        let rows = [
            SpendTransaction(amount: 1, date: date(2026, 1, 5), merchantName: "A", type: .variable, entryMethod: .imported, plaidAccountID: "a"),
            SpendTransaction(amount: 1, date: date(2026, 3, 5), merchantName: "B", type: .variable, entryMethod: .imported, plaidAccountID: "a"),
            SpendTransaction(amount: 1, date: date(2025, 1, 1), merchantName: "C", type: .variable, entryMethod: .imported, plaidAccountID: "b"),
            SpendTransaction(amount: 1, date: date(2024, 1, 1), merchantName: "D", type: .variable, entryMethod: .manual),
            SpendTransaction(amount: 1, date: date(2023, 1, 1), merchantName: "E", type: .variable, entryMethod: .imported)
        ]
        XCTAssertEqual(BudgetValidator.earliestImportedDate(selectedAccountIDs: ["a"], transactions: rows, calendar: calendar), date(2026, 1, 5))
        XCTAssertEqual(BudgetValidator.earliestImportedDate(selectedAccountIDs: ["a", "b"], transactions: rows, calendar: calendar), date(2025, 1, 1))
        XCTAssertNil(BudgetValidator.earliestImportedDate(selectedAccountIDs: ["z"], transactions: rows, calendar: calendar))
    }
}
