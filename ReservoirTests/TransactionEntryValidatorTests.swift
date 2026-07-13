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

    /// (a) Create mode, no rule match, user actively picks a non-default type — that's a
    /// deliberate override even though there was nothing to "suggest" against.
    func testCreateNoMatchUserPicksNonDefaultIsOverride() {
        XCTAssertTrue(TransactionEntryValidator.isManualOverride(
            suggestedType: nil,
            chosenType: .fixed,
            hasUserInteractedWithTypeControl: true,
            existingIsManualOverride: false
        ))
    }

    /// (b) Create mode, no rule match, user never touches the control — the default
    /// (`variable`) stands, not an override.
    func testCreateNoMatchUntouchedIsNotOverride() {
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(
            suggestedType: nil,
            chosenType: .variable,
            hasUserInteractedWithTypeControl: false,
            existingIsManualOverride: false
        ))
    }

    /// (c) A rule matches and the user's final choice agrees with it (whether by leaving
    /// it untouched or by touching the control and landing back on the same value) — not
    /// an override.
    func testMatchingRuleAcceptedIsNotOverride() {
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(
            suggestedType: .fixed,
            chosenType: .fixed,
            hasUserInteractedWithTypeControl: false,
            existingIsManualOverride: false
        ))
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(
            suggestedType: .fixed,
            chosenType: .fixed,
            hasUserInteractedWithTypeControl: true,
            existingIsManualOverride: false
        ))
    }

    /// (d) A rule matches and the user actively picks something different — an override.
    func testMatchingRuleDivergedFromIsOverride() {
        XCTAssertTrue(TransactionEntryValidator.isManualOverride(
            suggestedType: .fixed,
            chosenType: .variable,
            hasUserInteractedWithTypeControl: true,
            existingIsManualOverride: false
        ))
    }

    /// (e) Edit mode, user doesn't touch the type field at all this session — whatever
    /// the transaction's existing `isManualOverride` was must be preserved exactly, even
    /// if a rule now matches (or no longer matches) differently than before. This is the
    /// core fix: a later `MerchantRule` change must never silently flip this.
    func testEditModeUntouchedPreservesExistingValueRegardlessOfRuleState() {
        XCTAssertTrue(TransactionEntryValidator.isManualOverride(
            suggestedType: .variable,
            chosenType: .fixed,
            hasUserInteractedWithTypeControl: false,
            existingIsManualOverride: true
        ))
        XCTAssertFalse(TransactionEntryValidator.isManualOverride(
            suggestedType: .fixed,
            chosenType: .variable,
            hasUserInteractedWithTypeControl: false,
            existingIsManualOverride: false
        ))
    }
}
