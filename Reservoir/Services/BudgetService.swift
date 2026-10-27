import Foundation
import SwiftData
import OSLog

/// Persistence for the one app-wide `Budget` (reservoir-j8t) — the single choke point for
/// the "only one budget" invariant, same shape as `GoalAccountAssociationService`. Every
/// mutation goes through `PersistenceSaveHelper.saveOrRollback`.
enum BudgetService {
    private static let logger = Logger(subsystem: "com.reservoir.app", category: "BudgetService")

    /// The budget, or `nil`. If more than one row somehow exists (it can't through this
    /// service), the oldest wins so behavior stays deterministic.
    static func current(in modelContext: ModelContext) -> Budget? {
        let descriptor = FetchDescriptor<Budget>(sortBy: [SortDescriptor(\.createdAt)])
        return (try? modelContext.fetch(descriptor))?.first
    }

    /// Creates the budget, or — if one already exists — updates it in place, so a second
    /// "create" can never produce a second row. Returns a user-facing error, or `nil`.
    @discardableResult
    static func save(
        monthlyAmount: Decimal,
        startDate: Date,
        carriesAcrossMonths: Bool,
        selectedAccountIDs: [String],
        modelContext: ModelContext
    ) -> String? {
        if let existing = current(in: modelContext) {
            return update(
                existing,
                monthlyAmount: monthlyAmount,
                startDate: startDate,
                carriesAcrossMonths: carriesAcrossMonths,
                selectedAccountIDs: selectedAccountIDs,
                modelContext: modelContext
            )
        }
        let budget = Budget(
            monthlyAmount: monthlyAmount,
            startDate: startDate,
            carriesAcrossMonths: carriesAcrossMonths,
            selectedAccountIDs: selectedAccountIDs
        )
        return PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { modelContext.insert(budget) },
            rollback: { modelContext.delete(budget) },
            logger: logger
        )
    }

    static func update(
        _ budget: Budget,
        monthlyAmount: Decimal,
        startDate: Date,
        carriesAcrossMonths: Bool,
        selectedAccountIDs: [String],
        modelContext: ModelContext
    ) -> String? {
        let original = (budget.monthlyAmount, budget.startDate, budget.carriesAcrossMonths, budget.selectedAccountIDs)
        return PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: {
                budget.monthlyAmount = monthlyAmount
                budget.startDate = startDate
                budget.carriesAcrossMonths = carriesAcrossMonths
                budget.selectedAccountIDs = selectedAccountIDs
            },
            rollback: {
                budget.monthlyAmount = original.0
                budget.startDate = original.1
                budget.carriesAcrossMonths = original.2
                budget.selectedAccountIDs = original.3
            },
            logger: logger
        )
    }

    /// Deletes the budget. Transactions are untouched (no relationship).
    static func delete(_ budget: Budget, modelContext: ModelContext) -> String? {
        PersistenceSaveHelper.deleteWithRollback(budget, modelContext: modelContext, logger: logger)
    }
}
