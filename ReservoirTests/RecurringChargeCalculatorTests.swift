import XCTest
@testable import Reservoir

final class RecurringChargeCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }

    private func charge(_ d: Date, _ amount: Decimal, _ merchant: String, category: String? = "ENTERTAINMENT") -> CategorySpendCalculator.Entry {
        .init(date: d, amount: amount, category: category, merchant: merchant)
    }

    private let now = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 10, day: 31, hour: 12).date!

    func test_findsMonthlySubscription() {
        let entries = [
            charge(date(2026, 7, 14), 15.49, "Netflix"),
            charge(date(2026, 8, 14), 15.49, "Netflix"),
            charge(date(2026, 9, 14), 15.49, "Netflix"),
            charge(date(2026, 10, 14), 15.49, "Netflix"),
        ]
        let found = RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.merchant, "Netflix")
        XCTAssertEqual(found.first?.typicalAmount, 15.49)
        XCTAssertEqual(found.first?.chargeCount, 4)
        XCTAssertEqual(found.first?.category, "ENTERTAINMENT")
        XCTAssertFalse(found.first?.priceChanged ?? true)
        XCTAssertFalse(found.first?.isNew ?? true)
    }

    func test_flagsPriceChangeAndNew() {
        let entries = [
            charge(date(2026, 8, 20), 10, "Streamly"),
            charge(date(2026, 9, 20), 10, "Streamly"),
            charge(date(2026, 10, 20), 12, "Streamly"),
        ]
        let found = RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar)
        XCTAssertEqual(found.first?.previousAmount, 10)
        XCTAssertEqual(found.first?.lastAmount, 12)
        XCTAssertTrue(found.first?.isNew ?? false)
    }

    func test_ignoresTinyPriceDrift() {
        let entries = [
            charge(date(2026, 8, 20), 100, "Utility"),
            charge(date(2026, 9, 20), 101, "Utility"),
            charge(date(2026, 10, 20), 102, "Utility"),
        ]
        XCTAssertNil(RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar).first?.previousAmount)
    }

    func test_ignoresFrequentShops() {
        // A cafe visited every few days is not monthly.
        let entries = (0..<20).map { charge(date(2026, 10, 1).addingTimeInterval(Double($0) * 86_400), 4.5, "Corner Cafe") }
        XCTAssertTrue(RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar).isEmpty)
    }

    func test_ignoresTwoOccurrences() {
        let entries = [charge(date(2026, 9, 14), 15, "Hulu"), charge(date(2026, 10, 14), 15, "Hulu")]
        XCTAssertTrue(RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar).isEmpty)
    }

    func test_ignoresCancelledSubscription() {
        let entries = [
            charge(date(2026, 4, 14), 15, "Old Gym"),
            charge(date(2026, 5, 14), 15, "Old Gym"),
            charge(date(2026, 6, 14), 15, "Old Gym"),
        ]
        XCTAssertTrue(RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar).isEmpty)
    }

    func test_ignoresWildlyVaryingAmounts() {
        let entries = [
            charge(date(2026, 8, 5), 12, "Grocery Mart"),
            charge(date(2026, 9, 5), 90, "Grocery Mart"),
            charge(date(2026, 10, 5), 41, "Grocery Mart"),
        ]
        XCTAssertTrue(RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar).isEmpty)
    }

    func test_sortsByAmountAndTotals() {
        let small = (7...10).map { charge(date(2026, $0, 10), 10, "Small") }
        let big = (7...10).map { charge(date(2026, $0, 12), 50, "Big") }
        let found = RecurringChargeCalculator.detect(entries: small + big, now: now, calendar: calendar)
        XCTAssertEqual(found.map(\.merchant), ["Big", "Small"])
        XCTAssertEqual(RecurringChargeCalculator.monthlyTotal(found), 60)
    }

    func test_matchesMerchantCaseInsensitively() {
        let entries = [
            charge(date(2026, 8, 3), 9, "Spotify"),
            charge(date(2026, 9, 3), 9, "SPOTIFY"),
            charge(date(2026, 10, 3), 9, "spotify"),
        ]
        XCTAssertEqual(RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar).count, 1)
    }

    // MARK: - Totals and upcoming (reservoir-1cm, reservoir-nm8)

    private var twoSubscriptions: [CategorySpendCalculator.Entry] {
        [
            charge(date(2026, 7, 14), 15, "Netflix"), charge(date(2026, 8, 14), 15, "Netflix"),
            charge(date(2026, 9, 14), 15, "Netflix"), charge(date(2026, 10, 14), 15, "Netflix"),
            charge(date(2026, 8, 3), 10, "Streamly"), charge(date(2026, 9, 3), 10, "Streamly"),
            charge(date(2026, 10, 3), 12, "Streamly"),
        ]
    }

    func test_yearlyTotalIsTwelveMonths() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        XCTAssertEqual(RecurringChargeCalculator.monthlyTotal(found), 27)
        XCTAssertEqual(RecurringChargeCalculator.yearlyTotal(found), 324)
    }

    func test_monthlyPriceChangeSumsChangedCharges() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        XCTAssertEqual(RecurringChargeCalculator.monthlyPriceChange(found), 2)
        XCTAssertEqual(RecurringChargeCalculator.monthlyPriceChange([]), 0)
    }

    func test_headerTextMentionsYearAndPriceRise() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        let text = RecurringChargeCalculator.summaryText(found)
        XCTAssertTrue(text.contains("$27 a month"))
        XCTAssertTrue(text.contains("$324 a year"))
        XCTAssertTrue(text.contains("prices up $2"))
    }

    func test_upcomingListsChargesDueInTheNextWeekSoonestFirst() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        // Oct 31: Netflix next due Nov 14 (too far), Streamly Nov 3 (in 3 days).
        let upcoming = RecurringChargeCalculator.upcoming(found, now: now, calendar: calendar)
        XCTAssertEqual(upcoming.map(\.merchant), ["Streamly"])
        XCTAssertEqual(upcoming.first?.expectedDate, calendar.startOfDay(for: date(2026, 11, 3)))
        XCTAssertEqual(upcoming.first?.amount, 12)  // the new price, not the median

        let later = RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 10), calendar: calendar)
        XCTAssertEqual(later.map(\.merchant), ["Netflix"])
    }

    func test_upcomingIncludesTodayAndSkipsLateCharges() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        XCTAssertEqual(RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 3), calendar: calendar).map(\.merchant), ["Streamly"])
        // Streamly was due Nov 3: still listed two days late, dropped after that.
        XCTAssertEqual(RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 5), calendar: calendar).map(\.merchant), ["Streamly"])
        XCTAssertTrue(RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 6), calendar: calendar).isEmpty)
    }

    func test_upcomingWindowEdgeIsSevenDaysAhead() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        // Netflix is next due Nov 14: in on Nov 7 (7 days ahead), out on Nov 6 (8 days ahead).
        XCTAssertEqual(RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 7), calendar: calendar).map(\.merchant), ["Netflix"])
        XCTAssertTrue(RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 6), calendar: calendar).isEmpty)
    }

    func test_upcomingKeepsTheUsualDayAfterAShortMonth() {
        // Bills on the 31st (30th in 30-day months) posted on Feb 28 in a short month.
        let entries = [
            charge(date(2025, 12, 31), 50, "Gym"), charge(date(2026, 1, 31), 50, "Gym"),
            charge(date(2026, 2, 28), 50, "Gym"),
        ]
        let found = RecurringChargeCalculator.detect(entries: entries, now: date(2026, 3, 10), calendar: calendar)
        XCTAssertEqual(found.first?.usualDay, 31)
        let upcoming = RecurringChargeCalculator.upcoming(found, now: date(2026, 3, 29), calendar: calendar)
        XCTAssertEqual(upcoming.first?.expectedDate, calendar.startOfDay(for: date(2026, 3, 31)))
        // And the month after that is clamped to 30 days, not skipped.
        let april = RecurringChargeCalculator.upcoming(found.map { var f = $0; f.lastDate = date(2026, 3, 31); return f }, now: date(2026, 4, 28), calendar: calendar)
        XCTAssertEqual(april.first?.expectedDate, calendar.startOfDay(for: date(2026, 4, 30)))
    }

    func test_priceDropShowsInSummary() {
        let entries = [
            charge(date(2026, 8, 3), 20, "Streamly"), charge(date(2026, 9, 3), 20, "Streamly"),
            charge(date(2026, 10, 3), 15, "Streamly"),
        ]
        let found = RecurringChargeCalculator.detect(entries: entries, now: now, calendar: calendar)
        XCTAssertEqual(RecurringChargeCalculator.monthlyPriceChange(found), -5)
        XCTAssertTrue(RecurringChargeCalculator.summaryText(found).contains("prices down $5 a month"))
    }

    func test_totalOfUpcoming() {
        let found = RecurringChargeCalculator.detect(entries: twoSubscriptions, now: now, calendar: calendar)
        let upcoming = RecurringChargeCalculator.upcoming(found, now: date(2026, 11, 3), calendar: calendar)
        XCTAssertEqual(RecurringChargeCalculator.total(of: upcoming), 12)
    }
}
