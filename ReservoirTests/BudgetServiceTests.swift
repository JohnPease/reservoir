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
