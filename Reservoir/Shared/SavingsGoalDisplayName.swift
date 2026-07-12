import Foundation

/// A short, human-identifying label for a `SavingsGoal`, for UI contexts that need to name
/// a goal — the Transactions list's goal-attribution indicator and the transaction entry
/// form's attribution picker (adq.3). `SavingsGoal` has no `name` field (the data model is
/// fixed for this story — no schema change), so this derives a stable label from its
/// existing fields instead of adding one. Shared here (not duplicated across
/// `TransactionsView`/`TransactionEntryView`) per STANDARDS.md §3.
extension SavingsGoal {
    var displayName: String {
        "\(targetAmount.formatted(.currency(code: "USD"))) by \(targetDate.formatted(.dateTime.month(.abbreviated).day()))"
    }
}
