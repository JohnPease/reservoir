import XCTest
@testable import Reservoir

final class TransactionEntryValidatorTests: XCTestCase {

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

    private func makeGoal() -> SavingsGoal {
        SavingsGoal(
            targetAmount: 1000,
            targetDate: day(30),
            startDate: today,
            startingBalance: 0,
            dailyBase: 30
        )
    }

    // MARK: - Amount

    func testPositiveAmountPasses() {
        let result = TransactionEntryValidator.validate(
            amount: 12.50, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNil(result.amountError)
    }

    func testZeroAmountFails() {
        let result = TransactionEntryValidator.validate(
            amount: 0, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNotNil(result.amountError)
    }

    func testNegativeAmountFails() {
        let result = TransactionEntryValidator.validate(
            amount: -5, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNotNil(result.amountError)
    }

    // MARK: - Date

    func testDateOfTodayPasses() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNil(result.dateError)
    }

    func testPastDatePasses() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: day(-10), merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNil(result.dateError)
    }

    func testFutureDateFails() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: day(1), merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNotNil(result.dateError)
    }

    // MARK: - Merchant name

    func testNonEmptyMerchantNamePasses() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNil(result.merchantNameError)
    }

    func testEmptyMerchantNameFails() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNotNil(result.merchantNameError)
    }

    func testWhitespaceOnlyMerchantNameFails() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "   ",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNotNil(result.merchantNameError)
    }

    // MARK: - Goal attribution confirmation

    func testUnconfirmedGoalAttributionFails() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: false, referenceDate: today, calendar: calendar
        )
        XCTAssertNotNil(result.goalAttributionError)
        XCTAssertFalse(result.isValid)
    }

    func testConfirmedGoalAttributionPasses() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertNil(result.goalAttributionError)
    }

    func testAllFieldsValidIsValidTrue() {
        let result = TransactionEntryValidator.validate(
            amount: 10, date: today, merchantName: "Coffee Shop",
            hasConfirmedGoalAttribution: true, referenceDate: today, calendar: calendar
        )
        XCTAssertTrue(result.isValid)
    }

    // MARK: - goalAttributionRequirement

    func testSoleActiveGoalAutoSelects() {
        let goal = makeGoal()
        let requirement = TransactionEntryValidator.goalAttributionRequirement(activeGoals: [goal])
        XCTAssertEqual(requirement, .autoSelect(goal))
    }

    func testZeroActiveGoalsRequiresNoChoice() {
        let requirement = TransactionEntryValidator.goalAttributionRequirement(activeGoals: [])
        XCTAssertEqual(requirement, .noActiveGoals)
    }

    func testMultipleActiveGoalsRequiresExplicitChoice() {
        let requirement = TransactionEntryValidator.goalAttributionRequirement(activeGoals: [makeGoal(), makeGoal()])
        XCTAssertEqual(requirement, .explicitChoiceRequired)
    }

    // MARK: - isManualOverride

    func testNoSuggestionMeansNeverManualOverride() {
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(suggestedType: nil, chosenType: .variable))
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(suggestedType: nil, chosenType: .fixed))
    }

    func testChosenTypeMatchingSuggestionIsNotOverride() {
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(suggestedType: .fixed, chosenType: .fixed))
    }

    func testChosenTypeDivergingFromSuggestionIsOverride() {
        XCTAssertTrue(TransactionEntryValidator.isManualOverride(suggestedType: .fixed, chosenType: .variable))
    }
}
