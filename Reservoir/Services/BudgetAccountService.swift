import Foundation
import SwiftData
import OSLog

/// Budget <-> linked-account concerns (reservoir-j8t): keeping the budget's selected
/// accounts consistent with what's actually linked, and shaping the account picker's
/// rows. Never touches `GoalAccountAssociationService` or any goal's `associatedItemIDs`
/// — the budget's account selection is independent of goal associations.
enum BudgetAccountService {
    private static let logger = Logger(subsystem: "com.reservoir.app", category: "BudgetAccountService")

    // MARK: - Pruning

    /// Removes `itemID`'s accounts from the budget's selection. Must be called while
    /// `linkedAccountStore` still holds that item's accounts (i.e. before
    /// `LinkedAccountStore.removeAll(itemID:)` clears them), because the account IDs are
    /// read from it.
    @discardableResult
    static func prune(
        itemID: String,
        linkedAccountStore: LinkedAccountStoring = LinkedAccountStore(),
        modelContext: ModelContext
    ) -> String? {
        prune(itemIDs: [itemID], linkedAccountStore: linkedAccountStore, modelContext: modelContext)
    }

    /// Multi-item form (environment change drops every item at once) — one save.
    @discardableResult
    static func prune(
        itemIDs: [String],
        linkedAccountStore: LinkedAccountStoring = LinkedAccountStore(),
        modelContext: ModelContext
    ) -> String? {
        let ids = Set(itemIDs)
        let accountIDs = Set(linkedAccountStore.loadAll().filter { ids.contains($0.itemID) }.map(\.accountID))
        return prune(accountIDs: accountIDs, modelContext: modelContext)
    }

    @discardableResult
    static func prune(accountIDs: Set<String>, modelContext: ModelContext) -> String? {
        guard !accountIDs.isEmpty,
              let budget = BudgetService.current(in: modelContext),
              budget.selectedAccountIDs.contains(where: accountIDs.contains)
        else { return nil }
        let original = budget.selectedAccountIDs
        return PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { budget.selectedAccountIDs = original.filter { !accountIDs.contains($0) } },
            rollback: { budget.selectedAccountIDs = original },
            logger: logger
        )
    }

    /// Whether any of `itemID`'s accounts are part of `budget` — drives the unlink
    /// confirmation's budget warning.
    static func budgetIncludesAccounts(
        ofItem itemID: String,
        budget: Budget?,
        linkedAccountStore: LinkedAccountStoring = LinkedAccountStore()
    ) -> Bool {
        guard let budget, !budget.selectedAccountIDs.isEmpty else { return false }
        let selected = Set(budget.selectedAccountIDs)
        return linkedAccountStore.accounts(itemID: itemID).contains { selected.contains($0.accountID) }
    }

    static let unlinkWarning =
        "This account is part of your monthly budget. Kept transactions will stop counting toward it once the account is removed."

    // MARK: - Picker data

    struct PickerRow: Equatable, Identifiable {
        let id: String
        /// "Name ••mask", or just the name with no mask; "Closed account" for an account
        /// that's selected but no longer linked.
        let title: String
        let detail: String?
        let isClosed: Bool
    }

    struct PickerGroup: Equatable, Identifiable {
        let title: String
        let rows: [PickerRow]
        var id: String { title }
    }

    static let closedAccountTitle = "Closed account"
    static let closedAccountsGroupTitle = "Closed accounts"
    static let unknownInstitutionTitle = "Other accounts"

    /// Linked accounts grouped by institution (alphabetical; accounts keep store order),
    /// followed by a "Closed accounts" group for any selected ID missing from the store so
    /// it can still be deselected.
    static func pickerGroups(linkedAccounts: [LinkedAccount], selectedAccountIDs: [String]) -> [PickerGroup] {
        var order: [String] = []
        var rowsByInstitution: [String: [PickerRow]] = [:]
        for account in linkedAccounts {
            let institution = account.institutionName ?? unknownInstitutionTitle
            if rowsByInstitution[institution] == nil { order.append(institution) }
            rowsByInstitution[institution, default: []].append(
                PickerRow(id: account.accountID, title: displayName(account), detail: detail(account), isClosed: false)
            )
        }
        var groups = order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { PickerGroup(title: $0, rows: rowsByInstitution[$0] ?? []) }

        let known = Set(linkedAccounts.map(\.accountID))
        let closed = selectedAccountIDs.filter { !known.contains($0) }
        if !closed.isEmpty {
            groups.append(PickerGroup(
                title: closedAccountsGroupTitle,
                rows: closed.map { PickerRow(id: $0, title: closedAccountTitle, detail: nil, isClosed: true) }
            ))
        }
        return groups
    }

    /// "Name ••mask".
    static func displayName(_ account: LinkedAccount) -> String {
        guard let mask = account.mask, !mask.isEmpty else { return account.name }
        return "\(account.name) ••\(mask)"
    }

    /// "Checking", "Credit card" — subtype when Plaid gave one, else the type.
    static func detail(_ account: LinkedAccount) -> String {
        let raw = (account.subtype?.isEmpty == false ? account.subtype : nil) ?? account.type
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}
