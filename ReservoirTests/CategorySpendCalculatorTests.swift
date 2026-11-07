import XCTest
@testable import Reservoir

final class CategorySpendCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func entry(_ d: Date, _ amount: Decimal, _ category: String?) -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category)
    }

    func test_groupsByCategoryWithinMonthLargestFirst() {
        let entries = [
            entry(date(2026, 10, 1), 10, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 31), 15, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 5), 40, "TRANSPORTATION"),
            entry(date(2026, 9, 30), 99, "TRANSPORTATION"),
            entry(date(2026, 11, 1), 99, "TRANSPORTATION"),
        ]
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(month.total, 65)
        XCTAssertEqual(month.rows.map(\.category), ["TRANSPORTATION", "FOOD_AND_DRINK"])
        XCTAssertEqual(month.rows.last?.amount, 25)
        XCTAssertEqual(month.rows.last?.count, 2)
    }

    func test_uncategorizedSpendIsItsOwnRow() {
        let entries = [entry(date(2026, 10, 2), 5, nil), entry(date(2026, 10, 3), 7, "FOOD_AND_DRINK")]
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(month.rows.map(\.name), ["Food and drink", "Uncategorized"])
    }

    func test_emptyMonth() {
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: [], calendar: calendar)
        XCTAssertEqual(month, .init(rows: [], total: 0))
    }

    func test_displayName() {
        XCTAssertEqual(CategorySpendCalculator.displayName(for: "FOOD_AND_DRINK"), "Food and drink")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: "GENERAL_MERCHANDISE"), "General merchandise")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: "INCOME"), "Income")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: nil), "Uncategorized")
        XCTAssertEqual(CategorySpendCalculator.displayName(for: ""), "Uncategorized")
    }

    // MARK: - Comparison and history (reservoir-hnt)

    func test_completedMonthComparesWithWholePriorMonth() {
        let entries = [
            entry(date(2026, 9, 29), 30, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 2), 50, "FOOD_AND_DRINK"),
        ]
        let month = CategorySpendCalculator.month(
            containing: date(2026, 10, 15), entries: entries, now: date(2026, 11, 3), calendar: calendar
        )
        XCTAssertFalse(month.comparesPartialMonth)
        XCTAssertEqual(month.rows.first?.previousAmount, 30)
        XCTAssertEqual(month.rows.first?.change, 20)
        XCTAssertEqual(month.previousTotal, 30)
    }

    func test_currentMonthComparesWithSameDaysOfPriorMonth() {
        let entries = [
            entry(date(2026, 9, 3), 10, "FOOD_AND_DRINK"),
            entry(date(2026, 9, 20), 100, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 4), 25, "FOOD_AND_DRINK"),
        ]
        let month = CategorySpendCalculator.month(
            containing: date(2026, 10, 10), entries: entries, now: date(2026, 10, 5), calendar: calendar
        )
        XCTAssertTrue(month.comparesPartialMonth)
        XCTAssertEqual(month.rows.first?.previousAmount, 10, "only Sept 1-5 counts")
        XCTAssertEqual(month.rows.first?.change, 15)
    }

    func test_categoryOnlyInPriorMonthStillGetsARow() {
        let entries = [entry(date(2026, 9, 10), 40, "TRAVEL"), entry(date(2026, 10, 2), 5, "FOOD_AND_DRINK")]
        let month = CategorySpendCalculator.month(containing: date(2026, 10, 15), entries: entries, calendar: calendar)
        let travel = month.rows.first { $0.category == "TRAVEL" }
        XCTAssertEqual(travel?.amount, 0)
        XCTAssertEqual(travel?.count, 0)
        XCTAssertEqual(travel?.change, -40)
        XCTAssertEqual(month.rows.first?.category, "FOOD_AND_DRINK")
    }

    func test_historyListsSixMonthsOldestFirstWithZeros() {
        let entries = [
            entry(date(2026, 10, 2), 5, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 9), 7, "FOOD_AND_DRINK"),
            entry(date(2026, 7, 9), 20, "FOOD_AND_DRINK"),
            entry(date(2026, 10, 9), 99, "TRAVEL"),
            entry(date(2026, 4, 30), 99, "FOOD_AND_DRINK"),
        ]
        let history = CategorySpendCalculator.history(
            for: "FOOD_AND_DRINK", months: 6, endingAt: date(2026, 10, 15), entries: entries, calendar: calendar
        )
        XCTAssertEqual(history.map(\.amount), [0, 0, 20, 0, 0, 12])
        XCTAssertEqual(history.first?.monthStart, date(2026, 5, 1))
        XCTAssertEqual(history.last?.monthStart, date(2026, 10, 1))
    }

    func test_historyForUncategorizedUsesNilCategory() {
        let entries = [entry(date(2026, 10, 2), 5, nil), entry(date(2026, 10, 3), 8, "TRAVEL")]
        let history = CategorySpendCalculator.history(for: nil, months: 1, endingAt: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(history.map(\.amount), [5])
    }

    // MARK: - Detailed categories (reservoir-e1y)

    private func detailed(_ d: Date, _ amount: Decimal, _ detail: String?, category: String = "FOOD_AND_DRINK") -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category, categoryDetailed: detail)
    }

    func test_detailSplitsCategoryByDetailedLabelWithComparison() {
        let entries = [
            detailed(date(2026, 10, 2), 30, "FOOD_AND_DRINK_RESTAURANT"),
            detailed(date(2026, 10, 9), 20, "FOOD_AND_DRINK_RESTAURANT"),
            detailed(date(2026, 10, 3), 12, "FOOD_AND_DRINK_COFFEE"),
            detailed(date(2026, 9, 3), 8, "FOOD_AND_DRINK_COFFEE"),
            detailed(date(2026, 9, 4), 15, "FOOD_AND_DRINK_GROCERIES"),
            detailed(date(2026, 10, 4), 99, "TRANSPORTATION_TAXIS", category: "TRANSPORTATION"),
        ]
        let rows = CategorySpendCalculator.detail(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(rows.map(\.name), ["Restaurant", "Coffee", "Groceries"])
        XCTAssertEqual(rows.map(\.amount), [50, 12, 0])
        XCTAssertEqual(rows[1].change, 4)
        XCTAssertEqual(rows[2].change, -15, "a label with spend only last month still gets a row")
    }

    func test_detailLabelMissingIsOther() {
        let entries = [detailed(date(2026, 10, 2), 5, nil)]
        let rows = CategorySpendCalculator.detail(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(rows.map(\.name), ["Other"])
    }

    func test_displayNameForDetailedDropsThePrimaryPrefix() {
        XCTAssertEqual(CategorySpendCalculator.displayName(forDetailed: "FOOD_AND_DRINK_FAST_FOOD", in: "FOOD_AND_DRINK"), "Fast food")
        XCTAssertEqual(CategorySpendCalculator.displayName(forDetailed: "OTHER_THING", in: "FOOD_AND_DRINK"), "Other thing")
        XCTAssertEqual(CategorySpendCalculator.displayName(forDetailed: nil, in: "FOOD_AND_DRINK"), "Other")
    }

    // MARK: - Unusual months (reservoir-qj2)

    /// Entertainment: $50 in each of Jun-Sep, then `current` in October. Food: steady $100.
    private func calloutEntries(entertainmentThisMonth current: Decimal) -> [CategorySpendCalculator.Entry] {
        var entries: [CategorySpendCalculator.Entry] = []
        for month in 6...9 {
            entries.append(entry(date(2026, month, 5), 50, "ENTERTAINMENT"))
            entries.append(entry(date(2026, month, 6), 100, "FOOD_AND_DRINK"))
        }
        entries.append(entry(date(2026, 10, 5), current, "ENTERTAINMENT"))
        entries.append(entry(date(2026, 10, 6), 100, "FOOD_AND_DRINK"))
        return entries
    }

    func test_calloutFiresWhenWellAboveUsual() {
        let callouts = CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 130), now: date(2026, 11, 2), calendar: calendar
        )
        XCTAssertEqual(callouts.count, 1)
        XCTAssertEqual(callouts.first?.category, "ENTERTAINMENT")
        XCTAssertEqual(callouts.first?.usual, 50)
        XCTAssertEqual(callouts.first?.text, "Entertainment was 2.6× its usual")
        XCTAssertEqual(callouts.first?.detailText, "$130 vs about $50 a month")
    }

    func test_calloutForMonthInProgressSaysSoFar() {
        let callouts = CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 130), now: date(2026, 10, 20), calendar: calendar
        )
        XCTAssertEqual(callouts.first?.text, "Entertainment is already 2.6× its usual")
        XCTAssertEqual(callouts.first?.detailText, "$130 so far vs about $50 a month")
    }

    func test_calloutNeedsRatioAndDollarExcess() {
        // 1.4x usual: under the ratio.
        XCTAssertTrue(CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 70), calendar: calendar
        ).isEmpty)
        // 1.5x of $50 is only $25 over... exactly at the threshold fires; $74 (+$24) does not.
        XCTAssertTrue(CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 74), calendar: calendar
        ).isEmpty)
        XCTAssertEqual(CategorySpendCalculator.callouts(
            month: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 75), calendar: calendar
        ).count, 1)
    }

    func test_calloutIgnoresSmallUsualAmounts() {
        var entries = (6...9).map { entry(date(2026, $0, 5), 10, "TRAVEL") }
        entries.append(entry(date(2026, 10, 5), 90, "TRAVEL"))
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar).isEmpty,
                      "a $10 usual is too small to call out")
    }

    func test_calloutNeedsTwoEarlierMonthsOfData() {
        let entries = [entry(date(2026, 9, 5), 50, "ENTERTAINMENT"), entry(date(2026, 10, 5), 500, "ENTERTAINMENT")]
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar).isEmpty)
    }

    func test_calloutDoesNotCountMonthsBeforeTheFirstData() {
        // Data starts in August: usual is Aug-Sep = 60, not diluted by empty months before it.
        let entries = [
            entry(date(2026, 8, 5), 60, "ENTERTAINMENT"),
            entry(date(2026, 9, 5), 60, "ENTERTAINMENT"),
            entry(date(2026, 10, 5), 100, "ENTERTAINMENT"),
        ]
        let callouts = CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(callouts.first?.usual, 60)
    }

    func test_calloutIgnoresUncategorized() {
        var entries = (6...9).map { entry(date(2026, $0, 5), 50, nil) }
        entries.append(entry(date(2026, 10, 5), 500, nil))
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 15), entries: entries, calendar: calendar).isEmpty)
    }

    // MARK: - Merchants (reservoir-9n1)

    private func shop(_ d: Date, _ amount: Decimal, _ merchant: String, category: String = "FOOD_AND_DRINK") -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category, merchant: merchant)
    }

    func test_merchantsRankedWithComparisonAndCaseInsensitiveMatching() {
        let entries = [
            shop(date(2026, 10, 2), 10, "Blue Bottle"),
            shop(date(2026, 10, 9), 12, "BLUE BOTTLE"),
            shop(date(2026, 10, 3), 40, "Trader Joe's"),
            shop(date(2026, 9, 3), 5, "blue bottle"),
            shop(date(2026, 9, 4), 30, "Old Place"),
            shop(date(2026, 10, 4), 99, "Hotel", category: "TRAVEL"),
        ]
        let rows = CategorySpendCalculator.merchants(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(rows.map(\.amount), [40, 22, 0])
        XCTAssertEqual(rows[1].count, 2)
        XCTAssertEqual(rows[1].name, "BLUE BOTTLE", "shown as last seen")
        XCTAssertEqual(rows[1].change, 17)
        XCTAssertEqual(rows[2].name, "Old Place")
        XCTAssertEqual(rows[2].change, -30)
    }

    // MARK: - Day of week (reservoir-me1)

    func test_weekdayPatternNeedsEnoughCharges() {
        let entries = (1...7).map { shop(date(2026, 10, $0), 5, "Cafe") }
        XCTAssertNil(CategorySpendCalculator.weekdayPattern(for: "FOOD_AND_DRINK", months: 6, endingAt: date(2026, 10, 15), entries: entries, calendar: calendar))
    }

    func test_weekdayPatternFindsBusiestDay() {
        // Oct 3, 10, 17, 24, 31 2026 are Saturdays; add four weekday charges.
        var entries = [3, 10, 17, 24, 31].map { shop(date(2026, 10, $0), 20, "Brunch") }
        entries += [5, 6, 7, 8].map { shop(date(2026, 10, $0), 5, "Cafe") }
        entries.append(shop(date(2026, 3, 3), 500, "Too old"))
        let pattern = CategorySpendCalculator.weekdayPattern(for: "FOOD_AND_DRINK", months: 6, endingAt: date(2026, 10, 15), entries: entries, calendar: calendar)
        XCTAssertEqual(pattern?.chargeCount, 9)
        XCTAssertEqual(pattern?.busiest?.weekday, 7, "Saturday")
        XCTAssertEqual(pattern?.busiest?.amount, 100)
        XCTAssertEqual(pattern?.total, 120)
        XCTAssertEqual(try XCTUnwrap(pattern).busiestShare, 100.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(pattern?.days.count, 7)
        XCTAssertEqual(pattern?.days.first?.weekday, calendar.firstWeekday)
    }

    // MARK: - Same month last year (reservoir-35r)

    func test_sameMonthLastYearReturnsAmountWhenHistoryReachesBack() {
        let entries = [
            shop(date(2025, 10, 2), 30, "Cafe"),
            shop(date(2025, 10, 20), 15, "Cafe"),
            shop(date(2025, 10, 5), 99, "Hotel", category: "TRAVEL"),
            shop(date(2026, 10, 2), 60, "Cafe"),
        ]
        XCTAssertEqual(CategorySpendCalculator.sameMonthLastYear(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar), 45)
    }

    func test_sameMonthLastYearIsNilWhenHistoryStartsLater() {
        let entries = [shop(date(2025, 12, 2), 30, "Cafe"), shop(date(2026, 10, 2), 60, "Cafe")]
        XCTAssertNil(CategorySpendCalculator.sameMonthLastYear(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar))
    }

    func test_sameMonthLastYearIsZeroWhenHistoryCoversItButCategoryHadNoSpend() {
        let entries = [shop(date(2025, 10, 2), 30, "Hotel", category: "TRAVEL"), shop(date(2026, 10, 2), 60, "Cafe")]
        XCTAssertEqual(CategorySpendCalculator.sameMonthLastYear(for: "FOOD_AND_DRINK", month: date(2026, 10, 15), entries: entries, calendar: calendar), 0)
    }

    // MARK: - Month-end pace (reservoir-2zf)

    /// Food and drink: $150 in each of three earlier months.
    private func paceEntries(thisMonth: [(Int, Decimal)]) -> [CategorySpendCalculator.Entry] {
        let earlier = [(7, 15), (8, 15), (9, 15)].flatMap { month, day in
            [entry(date(2026, month, day), 150, "FOOD_AND_DRINK")]
        }
        return earlier + thisMonth.map { entry(date(2026, 10, $0.0), $0.1, "FOOD_AND_DRINK") }
    }

    func test_projectionFlagsCategoryOnPaceToRunHigh() {
        // $100 in the first 10 days of a 31-day month is a $310 pace against a usual $150, but it
        // is only 0.67x usual so far, so it is a projection and not a callout.
        let entries = paceEntries(thisMonth: [(3, 50), (8, 50)])
        let found = CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 10), calendar: calendar)
        XCTAssertEqual(found.map(\.category), ["FOOD_AND_DRINK"])
        XCTAssertEqual(found.first?.spent, 100)
        XCTAssertEqual(found.first?.usual, 150)
        XCTAssertEqual(NSDecimalNumber(decimal: found.first!.projected).doubleValue, 310, accuracy: 0.001)
        XCTAssertEqual(found.first?.detailText, "$100 so far, usually about $150")
    }

    func test_projectionWaitsForAWeekOfData() {
        let entries = paceEntries(thisMonth: [(2, 100)])
        XCTAssertTrue(CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 6), calendar: calendar).isEmpty)
    }

    func test_projectionLeavesOutCategoriesAlreadyCalledOut() {
        // $240 so far is already 1.6x usual: a callout, not a projection.
        let entries = paceEntries(thisMonth: [(3, 240)])
        XCTAssertTrue(CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 10), calendar: calendar).isEmpty)
    }

    func test_projectionIgnoresOnPaceAndFinishedMonths() {
        let steady = paceEntries(thisMonth: [(5, 50)])  // 31/10 x 50 = $155, near usual
        XCTAssertTrue(CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: steady, now: date(2026, 10, 10), calendar: calendar).isEmpty)
        let heavy = paceEntries(thisMonth: [(3, 50), (8, 50)])
        XCTAssertTrue(CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: heavy, now: date(2026, 11, 3), calendar: calendar).isEmpty)
    }

    func test_projectionNeedsTwoChargesSoFar() {
        // One $100 purchase on day 2 projects to $155 x 2, but a single charge is not a pace.
        let entries = paceEntries(thisMonth: [(2, 100)])
        XCTAssertTrue(CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 10), calendar: calendar).isEmpty)
    }

    func test_projectionPicksUpWhatCalloutsRejectOnDollarExcess() {
        // Usual $30, spent $47 (1.57x but only $17 over): not a callout, so it must be able to
        // appear as a projection ($47 over 10 days is a $146 pace).
        let earlier = [(7, 15), (8, 15), (9, 15)].map { entry(date(2026, $0.0, $0.1), 30, "ENTERTAINMENT") }
        let entries = earlier + [entry(date(2026, 10, 3), 20, "ENTERTAINMENT"), entry(date(2026, 10, 8), 27, "ENTERTAINMENT")]
        XCTAssertTrue(CategorySpendCalculator.callouts(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 10), calendar: calendar).isEmpty)
        let found = CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 10), calendar: calendar)
        XCTAssertEqual(found.map(\.category), ["ENTERTAINMENT"])
    }

    func test_projectionNeedsTwoEarlierMonths() {
        let entries = [entry(date(2026, 9, 15), 150, "FOOD_AND_DRINK"), entry(date(2026, 10, 3), 50, "FOOD_AND_DRINK"), entry(date(2026, 10, 5), 50, "FOOD_AND_DRINK")]
        XCTAssertTrue(CategorySpendCalculator.projections(month: date(2026, 10, 1), entries: entries, now: date(2026, 10, 10), calendar: calendar).isEmpty)
    }

    // MARK: - Unusually large charges (reservoir-cn4)

    private func shop(_ d: Date, _ amount: Decimal, _ merchant: String = "Corner Market", id: Int) -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: "FOOD_AND_DRINK", merchant: merchant, id: id)
    }

    func test_outlierFlagsChargeFarAboveMerchantUsual() {
        let entries = [
            shop(date(2026, 8, 1), 70, id: 1), shop(date(2026, 8, 20), 80, id: 2),
            shop(date(2026, 9, 10), 90, id: 3), shop(date(2026, 10, 5), 240, id: 4),
        ]
        let found = CategorySpendCalculator.outliers(entries: entries, calendar: calendar)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[4], 80)
    }

    func test_outlierNeedsRatioAndDollarExcess() {
        let entries = [
            shop(date(2026, 8, 1), 70, id: 1), shop(date(2026, 8, 20), 80, id: 2),
            shop(date(2026, 9, 10), 90, id: 3), shop(date(2026, 10, 5), 150, id: 4),  // 1.9x
            shop(date(2026, 8, 2), 5, "Kiosk", id: 5), shop(date(2026, 8, 9), 5, "Kiosk", id: 6),
            shop(date(2026, 8, 16), 5, "Kiosk", id: 7), shop(date(2026, 8, 23), 20, "Kiosk", id: 8),  // 4x but only $15 over
        ]
        XCTAssertTrue(CategorySpendCalculator.outliers(entries: entries, calendar: calendar).isEmpty)
    }

    func test_outlierNeedsThreeEarlierChargesAndSkipsSubscriptions() {
        let two = [shop(date(2026, 8, 1), 70, id: 1), shop(date(2026, 9, 10), 90, id: 2), shop(date(2026, 10, 5), 400, id: 3)]
        XCTAssertTrue(CategorySpendCalculator.outliers(entries: two, calendar: calendar).isEmpty)

        let four = two + [shop(date(2026, 7, 1), 80, id: 4)]
        XCTAssertEqual(CategorySpendCalculator.outliers(entries: four, calendar: calendar).keys.count, 1)
        XCTAssertTrue(CategorySpendCalculator.outliers(entries: four, excluding: ["corner market"], calendar: calendar).isEmpty)
    }

    func test_outlierOnlyComparesWithTheLastYear() {
        let entries = [
            shop(date(2024, 1, 1), 10, id: 1), shop(date(2024, 2, 1), 10, id: 2), shop(date(2024, 3, 1), 10, id: 3),
            shop(date(2026, 10, 5), 400, id: 4),
        ]
        XCTAssertTrue(CategorySpendCalculator.outliers(entries: entries, calendar: calendar).isEmpty)
    }

    func test_outlierIgnoresRefundsAndUsesEvenCountMedian() {
        let entries = [
            shop(date(2026, 7, 1), 60, id: 1), shop(date(2026, 8, 1), 100, id: 2),
            shop(date(2026, 8, 15), 70, id: 3), shop(date(2026, 9, 1), 90, id: 4),  // median of 60, 70, 90, 100 = 80
            shop(date(2026, 9, 10), -500, id: 5),  // refund: never an outlier, and not a prior charge
            shop(date(2026, 10, 5), 240, id: 6),
        ]
        let found = CategorySpendCalculator.outliers(entries: entries, calendar: calendar)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[6], 80)
    }

    func test_outlierSameTimestampChargesDoNotCountAsPrior() {
        let day = date(2026, 10, 5)
        let entries = [
            shop(date(2026, 8, 1), 80, id: 1), shop(date(2026, 8, 20), 80, id: 2), shop(date(2026, 9, 10), 80, id: 3),
            shop(day, 240, id: 4), shop(day, 250, id: 5),
        ]
        // Both are measured against the same three earlier charges, whatever the input order.
        XCTAssertEqual(Set(CategorySpendCalculator.outliers(entries: entries, calendar: calendar).keys), [4, 5])
        XCTAssertEqual(Set(CategorySpendCalculator.outliers(entries: entries.reversed(), calendar: calendar).keys), [4, 5])
    }

    // MARK: - Usual month (shared by callouts, pace and the trend footer)

    func test_usualMonthlyAveragesEarlierMonthsWithData() {
        let usual = CategorySpendCalculator.usualMonthly(
            for: "ENTERTAINMENT", before: date(2026, 10, 15), entries: calloutEntries(entertainmentThisMonth: 130), calendar: calendar
        )
        XCTAssertEqual(usual?.average, 50)
        XCTAssertEqual(usual?.months, 4, "June to September; nothing before the first month with data counts.")
    }

    func test_usualMonthlyNeedsTwoEarlierMonths() {
        let entries = [entry(date(2026, 9, 5), 50, "ENTERTAINMENT"), entry(date(2026, 10, 5), 90, "ENTERTAINMENT")]
        XCTAssertNil(CategorySpendCalculator.usualMonthly(for: "ENTERTAINMENT", before: date(2026, 10, 15), entries: entries, calendar: calendar))
    }
}
