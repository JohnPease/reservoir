import XCTest
@testable import Reservoir

final class BudgetWarningNotificationStoreTests: XCTestCase {
    private let suite = "BudgetWarningNotificationStoreTests"
    private var defaults: UserDefaults!
    private var store: BudgetWarningNotificationStore!

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = BudgetWarningNotificationStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        store = nil
    }

    func testEnabledDefaultsToFalseAndPersists() {
        XCTAssertFalse(store.isEnabled)
        store.isEnabled = true
        XCTAssertTrue(BudgetWarningNotificationStore(defaults: defaults).isEnabled)
        store.isEnabled = false
        XCTAssertFalse(store.isEnabled)
    }

    func testRecordRoundTripAndClear() {
        XCTAssertNil(store.loadRecord())
        let record = BudgetWarningNotificationRecord(month: BudgetWarningMonth(year: 2026, month: 11), level: .hardToRecover)
        store.saveRecord(record)
        XCTAssertEqual(BudgetWarningNotificationStore(defaults: defaults).loadRecord(), record)
        store.clearRecord()
        XCTAssertNil(store.loadRecord())
    }

    func testCorruptRecordLoadsNil() {
        defaults.set(Data("not json".utf8), forKey: BudgetWarningNotificationStore.recordKey)
        XCTAssertNil(store.loadRecord())
    }

    func testResetAllRemovesBothKeys() {
        store.isEnabled = true
        store.saveRecord(BudgetWarningNotificationRecord(month: BudgetWarningMonth(year: 2026, month: 11), level: .pointOfNoReturn))
        BudgetWarningNotificationStore.resetAll(defaults: defaults)
        XCTAssertFalse(store.isEnabled)
        XCTAssertNil(store.loadRecord())
    }
}
