import Foundation
import SwiftData

/// The slice of the live store that derived-state consumers (the widget snapshot, budget
/// warning notifications) read: every goal, the single budget, every transaction.
struct LiveStoreSnapshot {
    var goals: [SavingsGoal]
    var budget: Budget?
    var transactions: [SpendTransaction]

    /// `nil` when any fetch fails. The budget is the earliest-created one (the app keeps one).
    @MainActor
    static func fetch(from modelContext: ModelContext) -> LiveStoreSnapshot? {
        guard let goals = try? modelContext.fetch(FetchDescriptor<SavingsGoal>()),
              let budgets = try? modelContext.fetch(FetchDescriptor<Budget>(sortBy: [SortDescriptor(\.createdAt)])),
              let transactions = try? modelContext.fetch(FetchDescriptor<SpendTransaction>())
        else { return nil }
        return LiveStoreSnapshot(goals: goals, budget: budgets.first, transactions: transactions)
    }
}
