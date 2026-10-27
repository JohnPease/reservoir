import XCTest
@testable import Reservoir

/// reservoir-j8t PR1: `LinkedAccount` merge semantics, `LinkedAccountStore` persistence,
/// `PlaidAccountBackfillStore` flags, and the account-related unlink/environment-change
/// cleanup in `PlaidServiceLive`.
final class LinkedAccountStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "LinkedAccountStoreTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return UserDefaults(suiteName: suiteName)!
    }

    private func account(_ id: String, item: String = "item-1", name: String = "Checking", mask: String? = nil, subtype: String? = nil) -> LinkedAccount {
        LinkedAccount(accountID: id, itemID: item, name: name, mask: mask, type: "depository", subtype: subtype, institutionName: "Bank")
    }

    func test_upserting_addsNewAccountsAndNeverRemovesAbsentOnes() {
        let merged = LinkedAccount.upserting([account("B")], into: [account("A")])
        XCTAssertEqual(merged.map(\.accountID), ["A", "B"])
        XCTAssertEqual(LinkedAccount.upserting([], into: merged).map(\.accountID), ["A", "B"], "an empty page must not delete anything.")
    }

    func test_upserting_updatesInPlace_keepingOldOptionalsWhenUpdateOmitsThem() {
        let existing = [account("A", name: "Old", mask: "1234", subtype: "checking")]
        let merged = LinkedAccount.upserting([account("A", name: "New")], into: existing)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].name, "New")
        XCTAssertEqual(merged[0].mask, "1234")
        XCTAssertEqual(merged[0].subtype, "checking")
    }

    func test_initFromDTO_mapsFieldsAndDefaultsTypeToOther() throws {
        let json = #"{"account_id":"acc","name":"Plaid Checking","official_name":"Plaid Gold","mask":"0000","type":"depository","subtype":"checking"}"#
        let dto = try JSONDecoder().decode(PlaidAccount.self, from: Data(json.utf8))
        let mapped = LinkedAccount(dto, itemID: "item-1", institutionName: "Bank")
        XCTAssertEqual(mapped, LinkedAccount(accountID: "acc", itemID: "item-1", name: "Plaid Checking", officialName: "Plaid Gold", mask: "0000", type: "depository", subtype: "checking", institutionName: "Bank"))

        let sparse = try JSONDecoder().decode(PlaidAccount.self, from: Data(#"{"account_id":"x","name":"N"}"#.utf8))
        let sparseMapped = LinkedAccount(sparse, itemID: "i", institutionName: nil)
        XCTAssertEqual(sparseMapped.type, "other")
        XCTAssertNil(sparseMapped.officialName)
    }

    func test_store_persistsUpsertsAndRemovesPerItem() {
        let defaults = makeDefaults()
        let store = LinkedAccountStore(defaults: defaults)
        XCTAssertTrue(store.loadAll().isEmpty)
        store.upsert([account("A"), account("B", item: "item-2")])
        store.upsert([])
        store.upsert([account("A", name: "Renamed")])

        let reloaded = LinkedAccountStore(defaults: defaults)
        XCTAssertEqual(reloaded.loadAll().map(\.accountID), ["A", "B"])
        XCTAssertEqual(reloaded.accounts(itemID: "item-1").first?.name, "Renamed")

        reloaded.removeAll(itemID: "item-1")
        XCTAssertEqual(reloaded.loadAll().map(\.accountID), ["B"])
        reloaded.removeAll(itemID: "missing")
        XCTAssertEqual(reloaded.loadAll().count, 1)
    }

    func test_backfillStore_isScopedPerEnvironmentAndItem() {
        let store = PlaidAccountBackfillStore(defaults: makeDefaults())
        XCTAssertFalse(store.isComplete(for: .sandbox, itemID: "item-1"))
        store.setComplete(for: .sandbox, itemID: "item-1")
        XCTAssertTrue(store.isComplete(for: .sandbox, itemID: "item-1"))
        XCTAssertFalse(store.isComplete(for: .production, itemID: "item-1"))
        XCTAssertFalse(store.isComplete(for: .sandbox, itemID: "item-2"))
        store.clear(for: .sandbox, itemID: "item-1")
        XCTAssertFalse(store.isComplete(for: .sandbox, itemID: "item-1"))
    }

    func test_classifier_recognizesMutationDuringPaginationCode() {
        XCTAssertTrue(PlaidErrorClassifier.isSyncMutationDuringPagination(errorCode: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"))
        XCTAssertFalse(PlaidErrorClassifier.isSyncMutationDuringPagination(errorCode: "ITEM_LOGIN_REQUIRED"))
        XCTAssertFalse(PlaidErrorClassifier.isSyncMutationDuringPagination(errorCode: nil))
    }

    // MARK: - Unlink / environment change (PlaidServiceLive)

    @MainActor
    func test_unlink_removesThatItemsAccountsAndBackfillFlag_only() async {
        let items = StubLinkedItemStore(initial: LinkedItem(itemID: "item-1", institutionName: "Bank", linkedAt: .now))
        let accounts = StubLinkedAccountStore()
        accounts.upsert([account("A"), account("B", item: "item-2")])
        let backfill = StubAccountBackfillStore()
        backfill.setComplete(for: .sandbox, itemID: "item-1")
        backfill.setComplete(for: .sandbox, itemID: "item-2")
        let sut = PlaidServiceLive(
            keychain: StubKeychain(), urlSession: .shared, environmentStore: StubEnvironmentStore(.sandbox),
            cursorStore: StubCursorStore(), linkedItemStore: items, linkedAccountStore: accounts, backfillStore: backfill
        )

        await sut.unlink(LinkedItem(itemID: "item-1", institutionName: "Bank", linkedAt: .now))

        XCTAssertEqual(accounts.loadAll().map(\.accountID), ["B"])
        XCTAssertFalse(backfill.isComplete(for: .sandbox, itemID: "item-1"))
        XCTAssertTrue(backfill.isComplete(for: .sandbox, itemID: "item-2"))
    }

    @MainActor
    func test_environmentChange_removesAllLinkedItemsAccountsAndFlags() {
        let suiteName = "LinkedAccountStoreTests.env.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let environmentStore = PlaidEnvironmentStore(defaults: UserDefaults(suiteName: suiteName)!)
        let items = StubLinkedItemStore()
        items.save(LinkedItem(itemID: "item-1", institutionName: "One", linkedAt: .now))
        items.save(LinkedItem(itemID: "item-2", institutionName: "Two", linkedAt: .now))
        let accounts = StubLinkedAccountStore()
        accounts.upsert([account("A"), account("B", item: "item-2")])
        let backfill = StubAccountBackfillStore()
        backfill.setComplete(for: .sandbox, itemID: "item-1")
        let sut = PlaidServiceLive(
            keychain: StubKeychain(), urlSession: .shared, environmentStore: environmentStore,
            cursorStore: StubCursorStore(), linkedItemStore: items, linkedAccountStore: accounts, backfillStore: backfill
        )
        _ = sut

        environmentStore.set(.production)

        XCTAssertTrue(accounts.loadAll().isEmpty)
        XCTAssertFalse(backfill.isComplete(for: .sandbox, itemID: "item-1"))
    }
}
