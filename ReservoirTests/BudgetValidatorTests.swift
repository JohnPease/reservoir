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
        start: Date
    ) -> BudgetValidator.ValidationResult {
        BudgetValidator.validate(
            monthlyAmount: amount, selectedAccountIDs: accounts, startDate: start,
            referenceDate: today, calendar: calendar
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

    func testFloorIsSevenThirtyDaysBack() {
        let floor = BudgetValidator.startDateFloor(referenceDate: today, calendar: calendar)
        XCTAssertEqual(floor, calendar.date(byAdding: .day, value: -730, to: today))
        XCTAssertNil(validate(start: floor).startDateError)
        XCTAssertNotNil(validate(start: calendar.date(byAdding: .day, value: -1, to: floor)!).startDateError)
    }

    func testStartOfMonthIsAllowedRegardlessOfImportedHistory() {
        // A freshly linked phone may have no transaction on the 1st; the budget still starts there.
        XCTAssertNil(validate(start: date(2026, 10, 1)).startDateError)
    }

    func testDefaultStartDateIsFirstOfCurrentMonth() {
        XCTAssertEqual(BudgetValidator.defaultStartDate(referenceDate: today, calendar: calendar), date(2026, 10, 1))
    }
}
