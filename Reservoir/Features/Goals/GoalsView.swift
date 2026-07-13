import SwiftUI
import SwiftData
import OSLog

/// The Goals tab (adq.5): active goals, completed-but-undismissed goals, and the shared
/// zero-goals empty state. Dismissed goals never appear here (or anywhere) — dismissal
/// is terminal, per `TodayScreenCalculator`. All lifecycle filtering/sorting and
/// goal-specific math live in `TodayScreenCalculator`/`GoalsScreenCalculator`, not here
/// (STANDARDS.md §3).
struct GoalsView: View {
    @Environment(\.modelContext) private var modelContext

    /// The app's single shared "now," owned by `RootTabView` and kept current by the one
    /// `ReferenceDateKeeper` applied there — see `TodayClock`'s doc comment. Matches
    /// `TodayView`'s clock input (STANDARDS.md §3).
    @Environment(TodayClock.self) private var todayClock

    @Query(sort: \SavingsGoal.targetDate) private var goals: [SavingsGoal]

    @State private var isShowingCreateGoal = false
    @State private var goalPendingEdit: SavingsGoal?
    @State private var goalPendingDelete: SavingsGoal?
    @State private var actionError: String?

    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "GoalsView")

    /// Sorted by `targetDate` ascending (soonest first) — matches the Today screen's
    /// `@Query` sort convention, one sort convention across the app.
    private var activeGoals: [SavingsGoal] {
        TodayScreenCalculator.activeGoals(goals, referenceDate: todayClock.referenceDate, calendar: calendar)
    }

    private var completedGoals: [SavingsGoal] {
        TodayScreenCalculator.completedUndismissedGoals(goals, referenceDate: todayClock.referenceDate, calendar: calendar)
    }

    /// Shared with `TodayView` via `TodayScreenCalculator.hasNoGoalsAtAll` — previously a
    /// verbatim copy of `TodayView`'s identical private property (STANDARDS.md §3).
    private var hasNoGoalsAtAll: Bool {
        TodayScreenCalculator.hasNoGoalsAtAll(activeGoals: activeGoals, completedUndismissedGoals: completedGoals)
    }

    var body: some View {
        // Computed once here (not as accessed-per-use computed properties) so this
        // render's goal-list filtering (each an O(n) walk over `goals`) happens exactly
        // once each, not once per branch/`.isEmpty` check/`ForEach` that needs it — same
        // rationale as `ActiveGoalCardView.body`'s hoisted `carryForwardInput`/
        // `currentBalance` (code-review finding on PR #5).
        let activeGoals = activeGoals
        let completedGoals = completedGoals
        let hasNoGoalsAtAll = TodayScreenCalculator.hasNoGoalsAtAll(
            activeGoals: activeGoals,
            completedUndismissedGoals: completedGoals
        )

        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if hasNoGoalsAtAll {
                        NoActiveGoalPromptView(
                            onCreateGoal: { isShowingCreateGoal = true },
                            containerAccessibilityIdentifier: "goals.emptyState",
                            buttonAccessibilityIdentifier: "goals.createGoal"
                        )
                    } else {
                        if !activeGoals.isEmpty {
                            sectionHeader("Active goals")
                            ForEach(activeGoals, id: \.persistentModelID) { goal in
                                ActiveGoalCardView(
                                    goal: goal,
                                    referenceDate: todayClock.referenceDate,
                                    calendar: calendar,
                                    onEdit: { goalPendingEdit = goal },
                                    onDelete: { goalPendingDelete = goal }
                                )
                            }
                        }

                        if !completedGoals.isEmpty {
                            sectionHeader("Completed")
                            ForEach(completedGoals, id: \.persistentModelID) { goal in
                                CompletionBannerView(
                                    goal: goal,
                                    onDismiss: { dismiss(goal) },
                                    containerAccessibilityIdentifier: "goals.completedCard",
                                    dismissButtonAccessibilityIdentifier: "goals.completedCard.dismiss"
                                )
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Goals")
            .toolbar {
                if !hasNoGoalsAtAll {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingCreateGoal = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityIdentifier("goals.addGoal")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingCreateGoal) {
            GoalFormView(mode: .create, accessibilityIdentifier: "goals.createGoalSheet")
        }
        .editSheet(pendingItem: $goalPendingEdit) { goal in
            GoalFormView(mode: .edit(goal), accessibilityIdentifier: "goals.editGoalSheet")
        }
        .deleteConfirmation(
            pendingItem: $goalPendingDelete,
            title: deleteConfirmationTitle(for:),
            onDelete: delete
        )
        .saveErrorAlert($actionError)
    }

    /// "Delete this goal? Its N attributed transactions will no longer count toward any
    /// daily limit, but will not be deleted." — the transaction clause is omitted when
    /// N == 0, per the bead's exact copy.
    private func deleteConfirmationTitle(for goal: SavingsGoal) -> String {
        let count = goal.transactions.count
        guard count > 0 else { return "Delete this goal?" }
        let noun = count == 1 ? "transaction" : "transactions"
        return "Delete this goal? Its \(count) attributed \(noun) will no longer count toward any daily limit, but will not be deleted."
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// Reuses the same `modelContext.save()` + rollback-on-failure + error-alert pattern
    /// as `TodayView.dismiss(_:)`, via the shared `PersistenceSaveHelper` — not a
    /// duplicated implementation (STANDARDS.md §3).
    private func dismiss(_ goal: SavingsGoal) {
        actionError = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { goal.dismissedAt = .now },
            rollback: { goal.dismissedAt = nil },
            logger: logger
        )
    }

    /// Attributed `SpendTransaction`s are nullified, not deleted, by the existing
    /// `SchemaV1`/V2/V3 `.nullify` delete rule on `SavingsGoal.transactions` — no new
    /// calculator logic needed, only this action + save/rollback.
    ///
    /// SwiftData applies that `.nullify` relationship side effect to the affected
    /// transactions in-memory as soon as `modelContext.delete(goal)` runs, not only once
    /// `save()` actually succeeds. If `save()` then throws, re-inserting the goal alone
    /// (the old rollback) left those transactions permanently orphaned even though the
    /// deletion was "undone" — the goal came back but nothing pointed to it anymore.
    /// Capturing `affectedTransactions` before `mutate()` runs and re-linking each one's
    /// `savingsGoal` in `rollback()` restores both halves of the pre-delete state.
    private func delete(_ goal: SavingsGoal) {
        let affectedTransactions = goal.transactions
        actionError = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { modelContext.delete(goal) },
            rollback: {
                modelContext.insert(goal)
                for transaction in affectedTransactions {
                    transaction.savingsGoal = goal
                }
            },
            logger: logger
        )
    }
}
