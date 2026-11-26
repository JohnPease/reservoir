import XCTest
@testable import Reservoir

/// reservoir-nka.3: the pure decision table behind budget warning notifications.
final class BudgetWarningNotificationPlannerTests: XCTestCase {
    private typealias Planner = BudgetWarningNotificationPlanner

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let november = BudgetWarningMonth(year: 2026, month: 11)
    private let october = BudgetWarningMonth(year: 2026, month: 10)

    private func result(_ level: BudgetWarningLevel, year: Int = 2026, month: Int = 11) -> BudgetRecoveryCalculator.Result {
        BudgetRecoveryCalculator.Result(
            monthStart: calendar.date(from: DateComponents(year: year, month: month, day: 1))!,
            carryIn: 0,
            recovery: nil,
            warning: BudgetRecoveryCalculator.Warning(level: level),
            banner: nil
        )
    }

    private func input(
        enabled: Bool = true,
        authorization: NotificationAuthorization = .authorized,
        backfill: Bool = true,
        result: BudgetRecoveryCalculator.Result?,
        record: BudgetWarningNotificationRecord? = nil
    ) -> Planner.Input {
        Planner.Input(
            isEnabled: enabled, authorization: authorization, isAccountBackfillComplete: backfill,
            result: result, record: record, calendar: calendar
        )
    }

    private func record(_ month: BudgetWarningMonth, _ level: BudgetWarningLevel) -> BudgetWarningNotificationRecord {
        BudgetWarningNotificationRecord(month: month, level: level)
    }

    private func notification(_ decision: Planner.Decision) -> (BudgetWarningNotificationRecord, BudgetWarningNotificationContent)? {
        if case let .notify(record, content) = decision { return (record, content) }
        return nil
    }

    // MARK: Gates

    func testDisabledDoesNothing() {
        XCTAssertEqual(Planner.decide(input(enabled: false, result: result(.pointOfNoReturn))), .nothing)
    }

    func testNotDeterminedAndDeniedDoNothing() {
        for status in [NotificationAuthorization.notDetermined, .denied] {
            XCTAssertFalse(status.allowsDelivery)
            XCTAssertEqual(Planner.decide(input(authorization: status, result: result(.pointOfNoReturn))), .nothing)
        }
    }

    func testProvisionalAndEphemeralAllowDelivery() {
        for status in [NotificationAuthorization.authorized, .provisional, .ephemeral] {
            XCTAssertTrue(status.allowsDelivery)
        }
        let decision = Planner.decide(input(
            authorization: .provisional, result: result(.hardToRecover), record: record(november, .none)
        ))
        XCTAssertNotNil(notification(decision))
    }

    func testBackfillIncompleteClearsRecordAndNeverNotifies() {
        let decision = Planner.decide(input(
            backfill: false, result: result(.pointOfNoReturn), record: record(november, .none)
        ))
        XCTAssertEqual(decision, .clearRecord)
    }

    func testBackfillIncompleteWithoutRecordDoesNothing() {
        XCTAssertEqual(Planner.decide(input(backfill: false, result: result(.pointOfNoReturn))), .nothing)
    }

    func testNilResultKeepsRecord() {
        XCTAssertEqual(Planner.decide(input(result: nil, record: record(november, .hardToRecover))), .nothing)
    }

    // MARK: Baseline

    func testFirstEvaluationBaselinesSilentlyAtPointOfNoReturn() {
        XCTAssertEqual(
            Planner.decide(input(result: result(.pointOfNoReturn))),
            .saveRecord(record(november, .pointOfNoReturn))
        )
    }

    func testFirstEvaluationBaselinesSilentlyAtNone() {
        XCTAssertEqual(Planner.decide(input(result: result(.none))), .saveRecord(record(november, .none)))
    }

    // MARK: Transitions

    func testNoneToHardToRecoverNotifiesOnce() throws {
        let first = Planner.decide(input(result: result(.hardToRecover), record: record(november, .none)))
        let (saved, content) = try XCTUnwrap(notification(first))
        XCTAssertEqual(saved, record(november, .hardToRecover))
        XCTAssertEqual(content.title, "Hard to recover this month")
        // The saved record suppresses a second notification.
        XCTAssertEqual(Planner.decide(input(result: result(.hardToRecover), record: saved)), .nothing)
    }

    func testHardToRecoverToPointOfNoReturnNotifiesAgain() throws {
        let first = try XCTUnwrap(notification(Planner.decide(input(
            result: result(.hardToRecover), record: record(november, .trackingOver)
        ))))
        let second = try XCTUnwrap(notification(Planner.decide(input(
            result: result(.pointOfNoReturn), record: first.0
        ))))
        XCTAssertEqual(first.1.identifier, second.1.identifier)
        XCTAssertEqual(second.1.title, "Over budget this month")
        XCTAssertEqual(second.0.level, .pointOfNoReturn)
    }

    func testNoneToPointOfNoReturnNotifiesOnceWithOverBudgetCopy() throws {
        let (saved, content) = try XCTUnwrap(notification(Planner.decide(input(
            result: result(.pointOfNoReturn), record: record(november, .none)
        ))))
        XCTAssertEqual(content.title, "Over budget this month")
        XCTAssertEqual(Planner.decide(input(result: result(.pointOfNoReturn), record: saved)), .nothing)
    }

    func testTrackingOverNeverNotifiesButIsRecorded() {
        XCTAssertEqual(
            Planner.decide(input(result: result(.trackingOver), record: record(november, .none))),
            .saveRecord(record(november, .trackingOver))
        )
    }

    func testDipAndReRiseIsSilent() {
        // Recorded hardToRecover; level dips to none (nothing), rises back to hardToRecover (nothing).
        let recorded = record(november, .hardToRecover)
        XCTAssertEqual(Planner.decide(input(result: result(.none), record: recorded)), .nothing)
        XCTAssertEqual(Planner.decide(input(result: result(.hardToRecover), record: recorded)), .nothing)
    }

    func testFallingLevelFromBudgetEditDoesNothing() {
        XCTAssertEqual(
            Planner.decide(input(result: result(.hardToRecover), record: record(november, .pointOfNoReturn))),
            .nothing
        )
    }

    // MARK: Month rollover

    func testMonthRolloverResetsAndNotifiesWhenAlreadyWarned() throws {
        let decision = Planner.decide(input(
            result: result(.hardToRecover), record: record(october, .pointOfNoReturn)
        ))
        let (saved, content) = try XCTUnwrap(notification(decision))
        XCTAssertEqual(saved, record(november, .hardToRecover))
        XCTAssertEqual(content.identifier, "budget-warning.2026-11")
    }

    func testMonthRolloverAtLowLevelRecordsSilently() {
        XCTAssertEqual(
            Planner.decide(input(result: result(.trackingOver), record: record(october, .pointOfNoReturn))),
            .saveRecord(record(november, .trackingOver))
        )
        XCTAssertEqual(
            Planner.decide(input(result: result(.none), record: record(october, .hardToRecover))),
            .saveRecord(record(november, .none))
        )
    }

    func testMonthKeyStableAcrossTimeZoneChange() throws {
        // The record stores integers, so it still matches after the time zone changes and the
        // same month's start is recomputed in the new zone.
        var tokyo = calendar
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let tokyoStart = tokyo.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertNotEqual(tokyoStart, result(.none).monthStart)
        XCTAssertEqual(BudgetWarningMonth(containing: tokyoStart, calendar: tokyo), november)

        var moved = result(.hardToRecover)
        moved.monthStart = tokyoStart
        let decision = Planner.decide(Planner.Input(
            isEnabled: true, authorization: .authorized, isAccountBackfillComplete: true,
            result: moved, record: record(november, .hardToRecover), calendar: tokyo
        ))
        XCTAssertEqual(decision, .nothing)
    }

    // MARK: Content

    func testContentHasNoDigitsOrCurrencySymbol() throws {
        for level in [BudgetWarningLevel.hardToRecover, .pointOfNoReturn] {
            let content = try XCTUnwrap(Planner.content(for: level, month: november))
            for text in [content.title, content.body] {
                XCTAssertNil(text.rangeOfCharacter(from: .decimalDigits), text)
                XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "$€£¥")), text)
            }
            XCTAssertEqual(content.body, "Tap to see where you stand.")
        }
    }

    func testContentIdentifierIsPerMonth() throws {
        let november = try XCTUnwrap(Planner.content(for: .hardToRecover, month: november))
        let december = try XCTUnwrap(Planner.content(for: .hardToRecover, month: BudgetWarningMonth(year: 2026, month: 12)))
        let overNovember = try XCTUnwrap(Planner.content(for: .pointOfNoReturn, month: self.november))
        XCTAssertEqual(november.identifier, "budget-warning.2026-11")
        XCTAssertEqual(december.identifier, "budget-warning.2026-12")
        XCTAssertEqual(november.identifier, overNovember.identifier)
        XCTAssertEqual(november.threadIdentifier, "budget-warnings")
        XCTAssertEqual(november.deepLink, URL(string: "reservoir://today"))
    }

    func testContentNilBelowHardToRecover() {
        XCTAssertNil(Planner.content(for: .none, month: november))
        XCTAssertNil(Planner.content(for: .trackingOver, month: november))
    }

    func testTitlesMatchBannerStatusStrings() throws {
        XCTAssertEqual(BudgetRecoveryCalculator.status(.hardToRecover), "Hard to recover")
        XCTAssertEqual(BudgetRecoveryCalculator.status(.pointOfNoReturn), "Over budget")
        for level in [BudgetWarningLevel.hardToRecover, .pointOfNoReturn] {
            let content = try XCTUnwrap(Planner.content(for: level, month: november))
            XCTAssertEqual(content.title, "\(BudgetRecoveryCalculator.status(level)!) this month")
        }
    }

    func testMonthRecordRoundTripsThroughJSON() throws {
        let original = record(november, .hardToRecover)
        let decoded = try JSONDecoder().decode(BudgetWarningNotificationRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
