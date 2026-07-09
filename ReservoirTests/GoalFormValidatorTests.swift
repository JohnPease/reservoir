import XCTest
@testable import Reservoir

final class GoalFormValidatorTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
    }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: today)!
    }

    // MARK: - Creation: targetAmount

    func testCreationValidTargetAmountAboveStartingBalancePasses() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 100,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.targetAmountError)
    }

    func testCreationTargetAmountEqualToStartingBalanceFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 100,
            targetDate: day(30),
            startingBalance: 100,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetAmountError)
    }

    func testCreationTargetAmountBelowStartingBalanceFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 50,
            targetDate: day(30),
            startingBalance: 100,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetAmountError)
    }

    func testCreationMissingTargetAmountFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: nil,
            targetDate: day(30),
            startingBalance: 100,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetAmountError)
    }

    // MARK: - Creation: targetDate

    func testCreationTargetDateAfterTodayPasses() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(1),
            startingBalance: 0,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.targetDateError)
    }

    func testCreationTargetDateEqualToTodayFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: today,
            startingBalance: 0,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetDateError)
    }

    func testCreationTargetDateBeforeTodayFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(-1),
            startingBalance: 0,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetDateError)
    }

    // MARK: - Creation: startingBalance

    func testCreationStartingBalanceZeroPasses() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 0,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.startingBalanceError)
    }

    func testCreationNegativeStartingBalanceFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: -1,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.startingBalanceError)
    }

    func testCreationMissingStartingBalanceFails() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: nil,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.startingBalanceError)
    }

    // MARK: - Creation: startDate bounds (adq.5 backdating)

    func testCreationStartDateEqualToTodayPasses() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 0,
            startDate: today,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.startDateError)
    }

    func testCreationStartDateWithinNinetyDaysPasses() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 0,
            startDate: day(-14),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.startDateError)
    }

    func testCreationStartDateExactlyNinetyDaysAgoPasses() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 0,
            startDate: day(-90),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.startDateError)
    }

    func testCreationStartDateMoreThanNinetyDaysAgoFailsWithExactCopy() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 0,
            startDate: day(-91),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertEqual(result.startDateError, "Start date can't be more than 90 days ago")
    }

    func testCreationFutureStartDateFailsWithExactCopy() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 0,
            startDate: day(1),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertEqual(result.startDateError, "Start date can't be in the future")
    }

    func testCreationAllFieldsValidIsValidTrue() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 1000,
            targetDate: day(30),
            startingBalance: 100,
            startDate: day(-5),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertTrue(result.isValid)
    }

    func testCreationAnyInvalidFieldMakesIsValidFalse() {
        let result = GoalFormValidator.validateCreation(
            targetAmount: 50, // invalid: <= startingBalance
            targetDate: day(30),
            startingBalance: 100,
            startDate: day(-5),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertFalse(result.isValid)
    }

    // MARK: - Edit

    func testEditValidTargetAmountAndDatePasses() {
        let result = GoalFormValidator.validateEdit(
            targetAmount: 2000,
            targetDate: day(60),
            startingBalance: 100,
            startDate: day(-10),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertTrue(result.isValid)
    }

    func testEditTargetAmountBelowStartingBalanceFails() {
        let result = GoalFormValidator.validateEdit(
            targetAmount: 50,
            targetDate: day(60),
            startingBalance: 100,
            startDate: day(-10),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetAmountError)
    }

    func testEditTargetDateNotAfterTodayFails() {
        let result = GoalFormValidator.validateEdit(
            targetAmount: 2000,
            targetDate: today,
            startingBalance: 100,
            startDate: day(-10),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetDateError)
    }

    func testEditTargetDateNotAfterStartDateFails() {
        // referenceDate ("today") has moved earlier than startDate in this contrived
        // case to isolate the startDate half of the "after today AND after startDate"
        // rule; targetDate == startDate should still fail.
        let start = day(10)
        let result = GoalFormValidator.validateEdit(
            targetAmount: 2000,
            targetDate: start,
            startingBalance: 100,
            startDate: start,
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNotNil(result.targetDateError)
    }

    func testEditDoesNotValidateStartingBalanceOrStartDate() {
        // startingBalance/startDate are read-only post-creation — never flagged by edit
        // validation regardless of value.
        let result = GoalFormValidator.validateEdit(
            targetAmount: 2000,
            targetDate: day(60),
            startingBalance: 100,
            startDate: day(-10),
            referenceDate: today,
            calendar: calendar
        )
        XCTAssertNil(result.startingBalanceError)
        XCTAssertNil(result.startDateError)
    }
}
