import XCTest
@testable import Reservoir

/// Covers `docs/TODAY_SCREEN_REDESIGN_REQUIREMENTS.md` §5's required cases: positive
/// balance, negative balance, zero balance, and the display-floor behavior for a
/// deficit — plus the clamp behavior at the opposite end (a very large deficit), since
/// the floor and the clamp are two different mechanisms guarding two different ends of
/// the deficit range (see `FillGaugeCalculator.deficitDisplayFloor`'s doc comment).
final class FillGaugeCalculatorTests: XCTestCase {

    func test_positiveBalance_fillsProportionallyWithHealthyColor() {
        // 350 / (7 * 100) = 0.5
        let result = FillGaugeCalculator.result(currentBalance: 350, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .healthy)
    }

    func test_positiveBalance_aboveWindow_clampsToFull() {
        // 1000 / (7 * 100) > 1
        let result = FillGaugeCalculator.result(currentBalance: 1000, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .healthy)
    }

    func test_zeroBalance_isEmptyAndHealthy() {
        let result = FillGaugeCalculator.result(currentBalance: 0, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, 0, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .healthy)
    }

    func test_smallDeficit_isFlooredRatherThanRenderingEmpty() {
        // -35 / (7 * 100) = -0.05, magnitude below the 0.06 floor.
        let result = FillGaugeCalculator.result(currentBalance: -35, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, FillGaugeCalculator.deficitDisplayFloor, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .deficit)
    }

    func test_deficitAtExactlyTheFloor_staysAtTheFloor() {
        // -42 / (7 * 100) = -0.06, exactly the floor.
        let result = FillGaugeCalculator.result(currentBalance: -42, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, FillGaugeCalculator.deficitDisplayFloor, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .deficit)
    }

    func test_moderateDeficit_fillsProportionallyAboveTheFloor() {
        // -140 / (7 * 100) = -0.2, comfortably above the floor.
        let result = FillGaugeCalculator.result(currentBalance: -140, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .deficit)
    }

    func test_largeDeficit_clampsToFullRatherThanOverflowing() {
        // -1000 / (7 * 100) far exceeds -1; the clamp (not the floor) governs here.
        let result = FillGaugeCalculator.result(currentBalance: -1000, baseDailyAmount: 100)
        XCTAssertEqual(result.displayFill, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .deficit)
    }

    func test_zeroBaseDailyAmount_withPositiveBalance_treatsAsFullRatherThanDividingByZero() {
        let result = FillGaugeCalculator.result(currentBalance: 50, baseDailyAmount: 0)
        XCTAssertEqual(result.displayFill, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .healthy)
    }

    func test_zeroBaseDailyAmount_withNegativeBalance_treatsAsFullDeficitRatherThanDividingByZero() {
        let result = FillGaugeCalculator.result(currentBalance: -50, baseDailyAmount: 0)
        XCTAssertEqual(result.displayFill, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .deficit)
    }

    func test_zeroBaseDailyAmount_withZeroBalance_isEmptyAndHealthy() {
        let result = FillGaugeCalculator.result(currentBalance: 0, baseDailyAmount: 0)
        XCTAssertEqual(result.displayFill, 0, accuracy: 0.0001)
        XCTAssertEqual(result.colorRegime, .healthy)
    }

    // MARK: - signedFillPercent (the raw §4 formula, independent of display mapping)

    func test_signedFillPercent_matchesSpecFormula() {
        XCTAssertEqual(
            FillGaugeCalculator.signedFillPercent(currentBalance: 350, baseDailyAmount: 100),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            FillGaugeCalculator.signedFillPercent(currentBalance: -350, baseDailyAmount: 100),
            -0.5,
            accuracy: 0.0001
        )
    }

    func test_signedFillPercent_clampsToNegativeOneAndPositiveOne() {
        XCTAssertEqual(
            FillGaugeCalculator.signedFillPercent(currentBalance: 10_000, baseDailyAmount: 100),
            1.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            FillGaugeCalculator.signedFillPercent(currentBalance: -10_000, baseDailyAmount: 100),
            -1.0,
            accuracy: 0.0001
        )
    }
}
