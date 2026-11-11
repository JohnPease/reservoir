import XCTest
@testable import Reservoir

final class DayStepsCalculatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func purchase(_ merchant: String, _ amount: Decimal, minutes: Double) -> DayStepsCalculator.Purchase {
        .init(merchant: merchant, amount: amount, enteredAt: base.addingTimeInterval(minutes * 60))
    }

    func testStepsRunInEntryOrderAndEachShowsTheLevelAfterIt() {
        let day = DayStepsCalculator.day(
            limit: 106,
            purchases: [purchase("Trader Joe's", 17, minutes: 30), purchase("Blue Bottle", 6, minutes: 5)]
        )
        XCTAssertEqual(day.steps.map(\.merchant), ["Blue Bottle", "Trader Joe's"])
        XCTAssertEqual(day.steps.map(\.levelAfter), [100, 83])
        XCTAssertEqual(day.remaining, 83)
    }

    func testNoPurchasesLeavesTheTankFull() {
        let day = DayStepsCalculator.day(limit: 77, purchases: [])
        XCTAssertTrue(day.steps.isEmpty)
        XCTAssertEqual(day.remaining, 77)
    }

    func testOverspendingGoesNegative() {
        let day = DayStepsCalculator.day(limit: 20, purchases: [purchase("Dinner", 45, minutes: 1)])
        XCTAssertEqual(day.remaining, -25)
    }

    func testEqualTimesKeepTheirGivenOrder() {
        let day = DayStepsCalculator.day(limit: 50, purchases: [purchase("A", 5, minutes: 1), purchase("B", 10, minutes: 1)])
        XCTAssertEqual(day.steps.map(\.merchant), ["A", "B"])
    }

    func testFillIsClampedAndZeroWithoutALimit() {
        XCTAssertEqual(DayStepsCalculator.fill(level: 53, limit: 106), 0.5, accuracy: 0.0001)
        XCTAssertEqual(DayStepsCalculator.fill(level: -10, limit: 106), 0)
        XCTAssertEqual(DayStepsCalculator.fill(level: 200, limit: 106), 1)
        XCTAssertEqual(DayStepsCalculator.fill(level: 5, limit: 0), 0)
        XCTAssertEqual(DayStepsCalculator.fill(level: 5, limit: -3), 0)
    }

    func testSlicesStackUpwardFromTheWaterWithTheLatestPurchaseLowest() {
        let day = DayStepsCalculator.day(
            limit: 106,
            purchases: [purchase("Blue Bottle", 6, minutes: 1), purchase("Trader Joe's", 17, minutes: 2)]
        )
        XCTAssertEqual(DayStepsCalculator.slices(for: day), [
            .init(lower: 83, upper: 100),
            .init(lower: 100, upper: 106)
        ])
    }

    func testSlicesStopAtTheEmptyLineWhenTheDayIsOverdrawn() {
        let day = DayStepsCalculator.day(
            limit: 100,
            purchases: [purchase("A", 30, minutes: 1), purchase("B", 90, minutes: 2)]
        )
        // Remaining is -20: B spans -20...70 so it shows 0...70; A spans 70...100.
        XCTAssertEqual(DayStepsCalculator.slices(for: day), [
            .init(lower: 0, upper: 70),
            .init(lower: 70, upper: 100)
        ])
    }

    func testNoPurchasesMeansNoSlices() {
        XCTAssertTrue(DayStepsCalculator.slices(for: DayStepsCalculator.day(limit: 50, purchases: [])).isEmpty)
    }
}
