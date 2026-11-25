import XCTest
@testable import Reservoir

final class WidgetRecoveryLineFormatterTests: XCTestCase {
    private typealias Calc = BudgetRecoveryCalculator
    private typealias Formatter = WidgetRecoveryLineFormatter

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    private func date(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func result(
        level: BudgetWarningLevel = .none,
        needed: Decimal? = nil,
        overBy: Decimal? = nil,
        recovery: Calc.Outcome? = nil,
        banner: Calc.Banner? = nil
    ) -> Calc.Result {
        Calc.Result(
            monthStart: date(11, 1),
            carryIn: 0,
            recovery: recovery.map { Calc.Recovery(debt: 30, outcome: $0) },
            warning: Calc.Warning(level: level, neededDaily: needed, lowTypicalDaily: nil, headingOver: nil, overBy: overBy),
            banner: banner
        )
    }

    private func line(_ result: Calc.Result?) -> WidgetSnapshot.RecoveryLine? {
        Formatter.line(for: result, calendar: calendar)
    }

    // MARK: Outcomes

    func testNoResultOrNothingToSayIsNoLine() {
        XCTAssertNil(line(nil))
        XCTAssertNil(line(result()))
    }

    func testNoSpendSingularAndPlural() {
        XCTAssertEqual(line(result(recovery: .noSpend(days: 1, backOn: date(11, 3))))?.text, "1 no-spend day to full")
        XCTAssertEqual(line(result(recovery: .noSpend(days: 3, backOn: date(11, 5))))?.text, "3 no-spend days to full")
        XCTAssertEqual(line(result(recovery: .noSpend(days: 3, backOn: date(11, 5))))?.tone, .neutral)
    }

    func testResetClearsNamesTheFirst() {
        let found = line(result(recovery: .resetClears(days: 4, resetsOn: date(12, 1))))
        XCTAssertEqual(found?.text, "Resets to full Dec 1")
        XCTAssertEqual(found?.tone, .neutral)
    }

    func testTrackingOverAndHardToRecover() {
        let tracking = line(result(level: .trackingOver, needed: 41.99))
        XCTAssertEqual(tracking?.text, "Tracking over: $41/day")
        XCTAssertEqual(tracking?.tone, .warning)
        let hard = line(result(level: .hardToRecover, needed: 12))
        XCTAssertEqual(hard?.text, "Hard to recover: $12/day")
        XCTAssertEqual(hard?.tone, .warning)
    }

    func testNeedRoundsDownAndMatchesTheBannerFigure() {
        XCTAssertEqual(Formatter.needText("Tracking over", 41.99), "Tracking over: $41/day")
        XCTAssertEqual(Formatter.needText("Tracking over", 1), "Tracking over: $1/day")
        XCTAssertEqual(Formatter.needText("Tracking over", 1234.5), "Tracking over: $1,234/day")
        // Same helper the banner uses, so the dollar figure can't drift.
        XCTAssertEqual(BudgetRecoveryCalculator.neededText(41.99), "$41")
    }

    func testUnderADollar() {
        XCTAssertEqual(line(result(level: .trackingOver, needed: 0.99))?.text, "Tracking over: <$1/day")
        XCTAssertEqual(line(result(level: .hardToRecover, needed: 0.01))?.text, "Hard to recover: <$1/day")
    }

    func testZeroNegativeOrNilNeedMeansNoRoomLeft() {
        for needed in [Decimal(0), -5, -0.5] as [Decimal?] + [nil] {
            XCTAssertEqual(line(result(level: .trackingOver, needed: needed))?.text, "No room left this month")
            XCTAssertEqual(line(result(level: .hardToRecover, needed: needed))?.text, "No room left this month")
        }
    }

    func testPointOfNoReturnUsesBannerRounding() {
        let found = line(result(level: .pointOfNoReturn, needed: 5, overBy: 100.5))
        XCTAssertEqual(found?.text, "Over budget by \(BudgetSummaryCalculator.whole(100.5))")
        XCTAssertEqual(found?.text, "Over budget by $101")
        XCTAssertEqual(found?.tone, .overBudget)
    }

    // MARK: Precedence

    func testPrecedenceOrder() {
        let noSpend = Calc.Outcome.noSpend(days: 2, backOn: date(11, 4))
        // Over budget beats recovery.
        XCTAssertEqual(line(result(level: .pointOfNoReturn, overBy: 50, recovery: noSpend))?.tone, .overBudget)
        // Hard to recover beats recovery.
        XCTAssertEqual(line(result(level: .hardToRecover, needed: 9, recovery: noSpend))?.text, "Hard to recover: $9/day")
        // Recovery beats tracking over.
        XCTAssertEqual(line(result(level: .trackingOver, needed: 9, recovery: noSpend))?.text, "2 no-spend days to full")
    }

    // MARK: Accessibility and length

    func testAccessibilityTextIsTheChosenBannerSection() {
        let daily = Calc.Section(
            kind: .dailyLimit, title: "Daily limit", status: nil, level: nil,
            sentence: .init(lead: "2 no-spend days from tomorrow get your full $100 limit back.", deficitPhrase: nil, tail: "")
        )
        let month = Calc.Section(
            kind: .month, title: "November budget", status: "Tracking over", level: .trackingOver,
            sentence: .init(lead: "Keep to $9 a day.", deficitPhrase: nil, tail: "")
        )
        let banner = Calc.Banner(sections: [daily, month])
        let recoveryLine = line(result(level: .trackingOver, needed: 9, recovery: .noSpend(days: 2, backOn: date(11, 4)), banner: banner))
        XCTAssertEqual(recoveryLine?.accessibilityText, "Daily limit. 2 no-spend days from tomorrow get your full $100 limit back.")
        let warningLine = line(result(level: .trackingOver, needed: 9, banner: banner))
        XCTAssertEqual(warningLine?.accessibilityText, "November budget, Tracking over. Keep to $9 a day.")
        XCTAssertEqual(banner.accessibilityText, daily.accessibilityText + " " + month.accessibilityText)
    }

    func testAccessibilityFallsBackToTheTextWithoutABanner() {
        XCTAssertEqual(line(result(level: .trackingOver, needed: 9))?.accessibilityText, "Tracking over: $9/day")
    }

    func testLongestVariantsStayShort() {
        let variants: [WidgetSnapshot.RecoveryLine?] = [
            line(result(level: .pointOfNoReturn, overBy: 12_345)),
            line(result(level: .hardToRecover, needed: 999)),
            line(result(level: .trackingOver, needed: 999)),
            line(result(recovery: .noSpend(days: 99, backOn: date(11, 4)))),
            line(result(recovery: .resetClears(days: 99, resetsOn: date(12, 1)))),
            line(result(level: .hardToRecover, needed: 0)),
        ]
        for variant in variants {
            let text = try? XCTUnwrap(variant?.text)
            XCTAssertLessThanOrEqual(text?.count ?? 99, 26, text ?? "")
        }
    }
}
