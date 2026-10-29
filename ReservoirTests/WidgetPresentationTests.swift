import XCTest
@testable import Reservoir

final class WidgetPresentationTests: XCTestCase {
    private func snapshot(
        budget: WidgetSnapshot.Section,
        savings: WidgetSnapshot.Section,
        month: WidgetSnapshot.MonthProgress? = nil,
        tomorrowBudget: WidgetSnapshot.Section? = nil
    ) -> WidgetSnapshot {
        let today = WidgetSnapshot.Figures(budget: budget, savings: savings, month: month)
        var tomorrow = today
        if let tomorrowBudget { tomorrow.budget = tomorrowBudget }
        return WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 1_000), today: today, tomorrowStart: Date(timeIntervalSince1970: 90_000), tomorrow: tomorrow)
    }

    private let active = WidgetSnapshot.Section.active(remaining: 38.20, limit: 52.40, spentToday: 14.20)
    private let savingsActive = WidgetSnapshot.Section.active(remaining: 24.10, limit: 30, spentToday: 5.90)

    func testNoSnapshotIsSetUp() {
        XCTAssertEqual(WidgetPresentation.make(snapshot: nil, phase: .current, showsUpdatedCaption: false).body, .setUp)
    }

    func testNothingConfiguredIsSetUp() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: .notSet, savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.body, .setUp)
    }

    func testNeedsRefreshCarriesGeneratedAt() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: .notSet), phase: .needsRefresh, showsUpdatedCaption: true)
        XCTAssertEqual(p.body, .needsRefresh(lastUpdated: Date(timeIntervalSince1970: 1_000)))
        XCTAssertNil(p.updatedAt)
    }

    func testBudgetLeadsAndSavingsIsSmallSecondary() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: savingsActive), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.primary?.kind, .budget)
        XCTAssertEqual(p.smallSecondary?.kind, .savings)
    }

    func testBudgetOnlyHasNoSecondary() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertNil(p.smallSecondary)
    }

    func testSavingsOnlyLeadsWithSavings() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: .notSet, savings: savingsActive), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.primary?.kind, .savings)
        XCTAssertEqual(p.rectangularText.header, "Savings limit")
    }

    func testSyncingBudgetYieldsToSavingsAmount() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: .message(.syncing), savings: savingsActive), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.primary?.kind, .savings)
        XCTAssertNil(p.smallSecondary)
    }

    func testSyncingAndChooseAccountsMessages() {
        let syncing = WidgetPresentation.make(snapshot: snapshot(budget: .message(.syncing), savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(syncing.primary?.content, .message(.syncing))
        XCTAssertEqual(syncing.inlineText, "Syncing account data\u{2026}")
        let choose = WidgetPresentation.make(snapshot: snapshot(budget: .message(.chooseAccounts), savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(choose.rectangularText.headline, "Choose accounts")
    }

    func testOverBudgetUsesTypographicMinusAndWords() {
        let over = WidgetSnapshot.Section.active(remaining: -12.60, limit: 40, spentToday: 52.60)
        let p = WidgetPresentation.make(snapshot: snapshot(budget: over, savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertTrue(p.isOver)
        XCTAssertEqual(p.inlineText, "\u{2212}$12.60 over today")
        XCTAssertEqual(p.rectangularText, .init(header: "Budget", headline: "\u{2212}$12.60", detail: "over today"))
    }

    func testOverBudgetEstimateIsLabeledOnAccessoryFamilies() {
        let over = WidgetSnapshot.Section.active(remaining: -12.60, limit: 40, spentToday: 52.60)
        let p = WidgetPresentation.make(
            snapshot: snapshot(budget: active, savings: .notSet, tomorrowBudget: over), phase: .estimate, showsUpdatedCaption: false
        )
        XCTAssertEqual(p.inlineText, "\u{2212}$12.60 over today est.")
        XCTAssertEqual(p.rectangularText.detail, "over today \u{00B7} estimate")
    }

    func testEstimatePhaseUsesTomorrowFiguresAndLabels() {
        let tomorrow = WidgetSnapshot.Section.active(remaining: 52.40, limit: 52.40, spentToday: 0)
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: .notSet, tomorrowBudget: tomorrow), phase: .estimate, showsUpdatedCaption: true)
        XCTAssertTrue(p.isEstimate)
        XCTAssertEqual(p.primary?.content, .amount(remaining: 52.40, limit: 52.40))
        XCTAssertEqual(p.inlineText, "Left today $52.40 est.")
        XCTAssertNil(p.updatedAt)
    }

    func testUpdatedCaptionOnlyWhenRequested() {
        let s = snapshot(budget: active, savings: .notSet)
        XCTAssertNil(WidgetPresentation.make(snapshot: s, phase: .current, showsUpdatedCaption: false).updatedAt)
        XCTAssertEqual(WidgetPresentation.make(snapshot: s, phase: .current, showsUpdatedCaption: true).updatedAt, s.generatedAt)
    }

    func testRectangularAndInlineText() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.inlineText, "Left today $38.20")
        XCTAssertEqual(p.rectangularText, .init(header: "Budget", headline: "$38.20", detail: "left today \u{00B7} of $52.40"))
    }

    func testDeepLink() {
        XCTAssertTrue(WidgetDeepLink.isToday(WidgetDeepLink.todayURL))
        XCTAssertFalse(WidgetDeepLink.isToday(URL(string: "reservoir://goals")!))
    }

    func testCurrencyFormatting() {
        XCTAssertEqual(CurrencyFormatting.usd(1234.5), "$1,234.50")
        XCTAssertEqual(CurrencyFormatting.usdWithTypographicMinus(-12.6), "\u{2212}$12.60")
        XCTAssertEqual(CurrencyFormatting.usdWithTypographicMinus(12.6), "$12.60")
    }

    func testCurrencyFormattingEdgeCases() {
        XCTAssertEqual(CurrencyFormatting.usd(0), "$0.00")
        XCTAssertEqual(CurrencyFormatting.usd(-12.6), "-$12.60")
        XCTAssertEqual(CurrencyFormatting.usdWithTypographicMinus(0), "$0.00")
        XCTAssertEqual(CurrencyFormatting.usdWithTypographicMinus(-1234.5), "\u{2212}$1,234.50")
    }

    func testMediumMonthPanelDataFlowsThroughBody() {
        let month = WidgetSnapshot.MonthProgress(monthName: "October", sentence: "On pace.", spent: 100, monthlyAmount: 3100)
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: .notSet, month: month), phase: .current, showsUpdatedCaption: false)
        guard case .figures(_, _, let m) = p.body else { return XCTFail("expected figures") }
        XCTAssertEqual(m, month)
    }

    func testChooseAccountsBudgetWithActiveSavingsLeadsWithSavings() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: .message(.chooseAccounts), savings: savingsActive), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.primary?.kind, .savings)
        XCTAssertNil(p.smallSecondary)
    }

    func testSyncingStatesThenEstimateStillShowsNoCaption() {
        let p = WidgetPresentation.make(snapshot: snapshot(budget: active, savings: .notSet), phase: .estimate, showsUpdatedCaption: true)
        XCTAssertNil(p.updatedAt)
        XCTAssertEqual(p.rectangularText.detail, "left today \u{00B7} estimate \u{00B7} of $52.40")
    }

    func testActiveSectionMissingFiguresIsTreatedAsNotSet() {
        let broken = WidgetSnapshot.Section(state: .active)
        let p = WidgetPresentation.make(snapshot: snapshot(budget: broken, savings: .notSet), phase: .current, showsUpdatedCaption: false)
        XCTAssertEqual(p.body, .setUp)
    }

    func testLastUpdatedText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = WidgetPresentation.lastUpdatedText(now.addingTimeInterval(-2 * 86_400), now: now)
        XCTAssertTrue(text.hasPrefix("Last updated "))
        XCTAssertTrue(text.contains("2 days ago"))
    }
}
