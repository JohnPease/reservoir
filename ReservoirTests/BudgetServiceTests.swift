import XCTest
import SwiftData
@testable import Reservoir

final class BudgetServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, migrationPlan: ReservoirMigrationPlan.self, configurations: [configuration])
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
    }

    private func budgets() throws -> [Budget] { try context.fetch(FetchDescriptor<Budget>()) }

    private func seed(selected: [String]) throws -> Budget {
        XCTAssertNil(BudgetService.save(monthlyAmount: 1000, startDate: .now, carriesAcrossMonths: true, selectedAccountIDs: selected, modelContext: context))
        return try XCTUnwrap(BudgetService.current(in: context))
    }

    // MARK: - One budget

    func testSaveCreatesBudgetWithDefaults() throws {
        let budget = try seed(selected: ["a"])
        XCTAssertEqual(budget.monthlyAmount, 1000)
        XCTAssertTrue(budget.carriesAcrossMonths)
        XCTAssertEqual(budget.selectedAccountIDs, ["a"])
        XCTAssertEqual(try budgets().count, 1)
    }

    func testSecondSaveUpdatesInPlaceInsteadOfCreatingASecondBudget() throws {
        _ = try seed(selected: ["a"])
        XCTAssertNil(BudgetService.save(monthlyAmount: 2500, startDate: .now, carriesAcrossMonths: false, selectedAccountIDs: ["b"], modelContext: context))
        let all = try budgets()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.monthlyAmount, 2500)
        XCTAssertEqual(all.first?.carriesAcrossMonths, false)
        XCTAssertEqual(all.first?.selectedAccountIDs, ["b"])
    }

    func testDeleteRemovesBudgetAndLeavesTransactions() throws {
        let budget = try seed(selected: ["a"])
        context.insert(SpendTransaction(amount: 5, date: .now, merchantName: "M", type: .variable, entryMethod: .imported, plaidAccountID: "a"))
        try context.save()
        XCTAssertNil(BudgetService.delete(budget, modelContext: context))
        XCTAssertNil(BudgetService.current(in: context))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SpendTransaction>()).count, 1)
    }

    func testCurrentIsNilWithoutBudget() {
        XCTAssertNil(BudgetService.current(in: context))
    }

    // MARK: - Save failure rolls back

    /// A store seeded with one budget, then reopened read-only so every `save()` throws.
    private func makeReadOnlyContext(seedBudget: Bool) throws -> (context: ModelContext, storeURL: URL) {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BudgetServiceTests-\(UUID().uuidString)")
            .appendingPathExtension("store")
        let seedContainer = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url)]
        )
        let seedContext = ModelContext(seedContainer)
        if seedBudget {
            seedContext.insert(Budget(monthlyAmount: 1000, startDate: Date(timeIntervalSince1970: 1_700_000_000), carriesAcrossMonths: true, selectedAccountIDs: ["a", "b"]))
            try seedContext.save()
        }
        let readOnlyContainer = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: url, allowsSave: false)]
        )
        return (ModelContext(readOnlyContainer), url)
    }

    /// What actually landed on disk, read through a fresh writable container on the same file
    /// (a rolled-back insert/delete pair inside the failing read-only context is not a
    /// reliable signal on its own; see `TransactionImportServiceTests`' same approach).
    private func budgetsOnDisk(_ storeURL: URL) throws -> [Budget] {
        let schema = Schema(versionedSchema: SchemaV9.self)
        let container = try ModelContainer(
            for: schema, migrationPlan: ReservoirMigrationPlan.self,
            configurations: [ModelConfiguration(schema: schema, url: storeURL)]
        )
        let fresh = ModelContext(container)
        verificationContainers.append(container)
        return try fresh.fetch(FetchDescriptor<Budget>())
    }

    private var verificationContainers: [ModelContainer] = []

    func testCreateSaveFailureReturnsMessageAndPersistsNothing() throws {
        let (readOnly, url) = try makeReadOnlyContext(seedBudget: false)
        let error = BudgetService.save(monthlyAmount: 500, startDate: .now, carriesAcrossMonths: true, selectedAccountIDs: ["a"], modelContext: readOnly)
        XCTAssertNotNil(error)
        XCTAssertTrue(try budgetsOnDisk(url).isEmpty)
    }

    func testUpdateSaveFailureRestoresEveryField() throws {
        let (readOnly, _) = try makeReadOnlyContext(seedBudget: true)
        let budget = try XCTUnwrap(BudgetService.current(in: readOnly))
        let originalStart = budget.startDate
        let error = BudgetService.update(
            budget, monthlyAmount: 2500, startDate: .now, carriesAcrossMonths: false, selectedAccountIDs: ["z"], modelContext: readOnly
        )
        XCTAssertNotNil(error)
        XCTAssertEqual(budget.monthlyAmount, 1000)
        XCTAssertEqual(budget.startDate, originalStart)
        XCTAssertTrue(budget.carriesAcrossMonths)
        XCTAssertEqual(budget.selectedAccountIDs, ["a", "b"])
    }

    func testSaveOverExistingBudgetThatFailsDoesNotCreateASecondRow() throws {
        let (readOnly, _) = try makeReadOnlyContext(seedBudget: true)
        XCTAssertNotNil(BudgetService.save(monthlyAmount: 9, startDate: .now, carriesAcrossMonths: true, selectedAccountIDs: ["a"], modelContext: readOnly))
        XCTAssertEqual(try readOnly.fetch(FetchDescriptor<Budget>()).count, 1)
        XCTAssertEqual(BudgetService.current(in: readOnly)?.monthlyAmount, 1000)
    }

    func testDeleteSaveFailureKeepsTheStoredBudget() throws {
        let (readOnly, url) = try makeReadOnlyContext(seedBudget: true)
        let budget = try XCTUnwrap(BudgetService.current(in: readOnly))
        XCTAssertNotNil(BudgetService.delete(budget, modelContext: readOnly))
        XCTAssertEqual(try budgetsOnDisk(url).count, 1, "a failed delete leaves the stored budget in place.")
    }

    func testPruneSaveFailureRestoresSelection() throws {
        let (readOnly, _) = try makeReadOnlyContext(seedBudget: true)
        let budget = try XCTUnwrap(BudgetService.current(in: readOnly))
        XCTAssertNotNil(BudgetAccountService.prune(accountIDs: ["a"], modelContext: readOnly))
        XCTAssertEqual(budget.selectedAccountIDs, ["a", "b"])
    }

    func testEmptySelectionAfterPruningEverythingKeepsBudgetRow() throws {
        let budget = try seed(selected: ["a1", "a2"])
        XCTAssertNil(BudgetAccountService.prune(itemID: "item-1", linkedAccountStore: store(), modelContext: context))
        XCTAssertEqual(budget.selectedAccountIDs, [])
        XCTAssertNotNil(BudgetService.current(in: context))
        XCTAssertEqual(BudgetCalculator.cardState(for: budget, isAccountBackfillComplete: true), .chooseAccounts)
    }

    func testEnvironmentChangePruneDropsEveryItemsAccountsInOneSave() throws {
        let budget = try seed(selected: ["a1", "b1", "keep"])
        XCTAssertNil(BudgetAccountService.prune(itemIDs: ["item-1", "item-2"], linkedAccountStore: store(), modelContext: context))
        XCTAssertEqual(budget.selectedAccountIDs, ["keep"])
    }

    // MARK: - Prune

    private func store() -> StubLinkedAccountStore {
        let store = StubLinkedAccountStore()
        store.upsert([
            LinkedAccount(accountID: "a1", itemID: "item-1", name: "Checking", mask: "1234", type: "depository", subtype: "checking", institutionName: "Chase"),
            LinkedAccount(accountID: "a2", itemID: "item-1", name: "Card", mask: "9", type: "credit", subtype: "credit card", institutionName: "Chase"),
            LinkedAccount(accountID: "b1", itemID: "item-2", name: "Savings", type: "depository", subtype: "savings", institutionName: "Ally")
        ])
        return store
    }

    func testPruneRemovesOnlyThatItemsAccounts() throws {
        let budget = try seed(selected: ["a1", "b1", "a2"])
        XCTAssertNil(BudgetAccountService.prune(itemID: "item-1", linkedAccountStore: store(), modelContext: context))
        XCTAssertEqual(budget.selectedAccountIDs, ["b1"])
    }

    func testPruneLastAccountLeavesEmptySelectionAndKeepsBudget() throws {
        let budget = try seed(selected: ["b1"])
        BudgetAccountService.prune(itemID: "item-2", linkedAccountStore: store(), modelContext: context)
        XCTAssertEqual(budget.selectedAccountIDs, [])
        XCTAssertEqual(BudgetCalculator.cardState(for: budget, isAccountBackfillComplete: true), .chooseAccounts)
        XCTAssertEqual(try budgets().count, 1)
    }

    func testPruneMultipleItemsAtOnce() throws {
        let budget = try seed(selected: ["a1", "b1", "zzz"])
        BudgetAccountService.prune(itemIDs: ["item-1", "item-2"], linkedAccountStore: store(), modelContext: context)
        XCTAssertEqual(budget.selectedAccountIDs, ["zzz"])
    }

    func testPruneNoopsWithoutBudgetOrOverlapOrAccounts() throws {
        XCTAssertNil(BudgetAccountService.prune(itemID: "item-1", linkedAccountStore: store(), modelContext: context))
        let budget = try seed(selected: ["b1"])
        XCTAssertNil(BudgetAccountService.prune(itemID: "item-1", linkedAccountStore: store(), modelContext: context))
        XCTAssertNil(BudgetAccountService.prune(itemID: "unknown", linkedAccountStore: store(), modelContext: context))
        XCTAssertEqual(budget.selectedAccountIDs, ["b1"])
    }

    func testPruneAfterStoreClearedCannotFindAccounts() throws {
        // Documents why callers must prune BEFORE LinkedAccountStore.removeAll.
        let budget = try seed(selected: ["a1"])
        let linked = store()
        linked.removeAll(itemID: "item-1")
        BudgetAccountService.prune(itemID: "item-1", linkedAccountStore: linked, modelContext: context)
        XCTAssertEqual(budget.selectedAccountIDs, ["a1"])
    }

    func testBudgetIncludesAccountsOfItem() throws {
        let budget = try seed(selected: ["a2"])
        let linked = store()
        XCTAssertTrue(BudgetAccountService.budgetIncludesAccounts(ofItem: "item-1", budget: budget, linkedAccountStore: linked))
        XCTAssertFalse(BudgetAccountService.budgetIncludesAccounts(ofItem: "item-2", budget: budget, linkedAccountStore: linked))
        XCTAssertFalse(BudgetAccountService.budgetIncludesAccounts(ofItem: "item-1", budget: nil, linkedAccountStore: linked))
    }

    // MARK: - Picker

    func testPickerGroupsByInstitutionWithNamesMasksAndDetails() {
        let groups = BudgetAccountService.pickerGroups(linkedAccounts: store().loadAll(), selectedAccountIDs: [])
        XCTAssertEqual(groups.map(\.title), ["Ally", "Chase"])
        XCTAssertEqual(groups[1].rows.map(\.title), ["Checking ••1234", "Card ••9"])
        XCTAssertEqual(groups[1].rows.map(\.detail), ["Checking", "Credit card"])
        XCTAssertEqual(groups[0].rows.first?.title, "Savings", "no mask means no bullets")
    }

    func testPickerShowsClosedAccountRowsForSelectionMissingFromStore() {
        let groups = BudgetAccountService.pickerGroups(linkedAccounts: store().loadAll(), selectedAccountIDs: ["a1", "gone"])
        let closed = try? XCTUnwrap(groups.last)
        XCTAssertEqual(closed?.title, "Closed accounts")
        XCTAssertEqual(closed?.rows, [.init(id: "gone", title: "Closed account", detail: nil, isClosed: true)])
    }

    func testPickerPutsInstitutionlessAccountsInOtherGroup() {
        let orphan = LinkedAccount(accountID: "x", itemID: "i", name: "Mystery", type: "other")
        let groups = BudgetAccountService.pickerGroups(linkedAccounts: [orphan], selectedAccountIDs: [])
        XCTAssertEqual(groups.map(\.title), ["Other accounts"])
        XCTAssertEqual(groups[0].rows[0].detail, "Other")
    }
}
