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
}
