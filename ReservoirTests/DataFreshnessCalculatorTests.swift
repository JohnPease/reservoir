import XCTest
@testable import Reservoir

final class DataFreshnessCalculatorTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)
    private lazy var now = date(2026, 10, 29, 18)

    override func setUp() {
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func test_nothingToSay_returnsNil() {
        XCTAssertNil(DataFreshnessCalculator.text(lastSync: nil, newestImportedDate: nil, now: now, calendar: calendar))
    }

    func test_syncedToday_latestYesterday() {
        let text = DataFreshnessCalculator.text(lastSync: date(2026, 10, 29, 15), newestImportedDate: date(2026, 10, 28), now: now, calendar: calendar)
        XCTAssertTrue(text?.hasPrefix("Synced ") == true)
        XCTAssertTrue(text?.hasSuffix("latest imported charge yesterday") == true)
        XCTAssertFalse(text?.contains("Oct") == true)
    }

    func test_syncedEarlierDay_latestOlderDate() {
        let text = DataFreshnessCalculator.text(lastSync: date(2026, 10, 27, 17), newestImportedDate: date(2026, 10, 25), now: now, calendar: calendar)
        XCTAssertTrue(text?.contains("Synced Oct 27") == true)
        XCTAssertTrue(text?.hasSuffix("latest imported charge Oct 25") == true)
    }

    func test_latestToday() {
        let text = DataFreshnessCalculator.text(lastSync: nil, newestImportedDate: date(2026, 10, 29), now: now, calendar: calendar)
        XCTAssertEqual(text, "latest imported charge today")
    }
}
