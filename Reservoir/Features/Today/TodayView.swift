import SwiftUI
import SwiftData
import OSLog

/// The Today tab — the app's launch screen and the home of the core mechanic. Layout
/// per `docs/PROJECT_SPEC.md` "UX design — Today screen": date header, hero daily-limit
/// number, two-stat row, recent transactions, single "Add transaction" primary action.
///
/// All calculation (goal lifecycle, the `SavingsGoal`/`SpendTransaction` ->
/// `GoalCarryForwardInput` mapping, the spent/remaining summary) lives in
/// `TodayScreenCalculator`, not here — this view only lays things out and reacts to
/// state changes (STANDARDS.md §3).
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext

    /// The app's single shared "now," owned by `RootTabView` and kept current by the one
    /// `ReferenceDateKeeper` applied there — see `TodayClock`'s doc comment for why this
    /// replaced a local `@State` + per-view `.keepingReferenceDateCurrent(...)`. Not
    /// itself business logic — just the clock input to `TodayScreenCalculator`.
    @Environment(TodayClock.self) private var todayClock

    @Query(sort: \SavingsGoal.targetDate) private var goals: [SavingsGoal]
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]

    /// Read for `isAccountBackfillComplete` only (budget card gating) and the tab switch
    /// to Plans from the "Choose accounts" state.
    @Environment(TransactionImportService.self) private var importService: TransactionImportService?
    @Environment(TabSelection.self) private var tabSelection
    /// Sorted so `spentToday`'s filtering doesn't have to fault/sort the whole table on
    /// every body re-evaluation to find today's entries; still unlimited because
    /// `spentToday` needs every transaction dated today, not just the most recent ones.
    @Query(sort: \SpendTransaction.date, order: .reverse) private var transactions: [SpendTransaction]
    /// Store-level equivalent of `TodayScreenCalculator.recentTransactions`'s ordering
    /// (date desc, `createdAt` desc tiebreak) with a `fetchLimit`, so SwiftData does the
    /// sort/limit instead of fetching the full history into memory just to take the top
    /// 3. `recentTransactions` (the pure function) stays in `TodayScreenCalculator` and
    /// under test as the source of truth for the ordering rule; this query mirrors it at
    /// the persistence layer for performance.
    @Query(Self.recentTransactionsDescriptor)
    private var recentTransactionsQuery: [SpendTransaction]

    private static var recentTransactionsDescriptor: FetchDescriptor<SpendTransaction> {
        var descriptor = FetchDescriptor<SpendTransaction>(
            sortBy: [
                SortDescriptor(\.date, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse)
            ]
        )
        descriptor.fetchLimit = 3
        return descriptor
    }

    @State private var isShowingAddTransaction = false
    @State private var isShowingCreateGoal = false
    @State private var isShowingCreateBudget = false
    @State private var dismissError: String?

    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "TodayView")

    private var activeGoals: [SavingsGoal] {
        TodayScreenCalculator.activeGoals(goals, referenceDate: todayClock.referenceDate, calendar: calendar)
    }

    private var completedGoals: [SavingsGoal] {
        TodayScreenCalculator.completedUndismissedGoals(goals, referenceDate: todayClock.referenceDate, calendar: calendar)
    }

    private var summary: TodayScreenCalculator.Summary? {
        TodayScreenCalculator.summary(
            activeGoals: activeGoals,
            completedUndismissedGoals: completedGoals,
            allTransactions: transactions,
            referenceDate: todayClock.referenceDate,
            calendar: calendar
        )
    }

    /// True only when there is truly nothing to show for goals — no active goal and no
    /// completed-but-undismissed goal either. Distinct from `summary == nil`, which is
    /// also true whenever there's no active goal even if a completion banner is showing;
    /// using that alone to gate the empty-state prompt made the prompt render underneath
    /// a completion banner, which is a real (fixed) bug. Shared with `GoalsView` via
    /// `TodayScreenCalculator.hasNoGoalsAtAll` (STANDARDS.md §3).
    private var hasNoGoalsAtAll: Bool {
        TodayScreenCalculator.hasNoGoalsAtAll(activeGoals: activeGoals, completedUndismissedGoals: completedGoals)
    }

    /// Today's spend attributable to a completed-but-undismissed goal or unattributed
    /// entirely, for display when there's no active goal (so `summary` is `nil` and the
    /// hero/two-stat row aren't shown) but that spend still shouldn't disappear from the
    /// screen.
    private var spentTodayWithoutActiveGoal: Decimal {
        TodayScreenCalculator.spentToday(
            allTransactions: transactions,
            attributedGoals: completedGoals,
            referenceDate: todayClock.referenceDate,
            calendar: calendar
        )
    }

    private var recentTransactions: [SpendTransaction] {
        recentTransactionsQuery
    }

    /// Pace sentence figures; Today renders only the sentence. Wording is in
    /// `BudgetSummaryCalculator`.
    private func budgetInsights(_ model: BudgetCalculator.CardModel) -> BudgetSummaryCalculator.BudgetInsights? {
        BudgetSummaryCalculator.insights(
            budget: budgets.first,
            transactions: transactions,
            isAccountBackfillComplete: importService?.isAccountBackfillComplete ?? true,
            referenceDate: todayClock.referenceDate,
            summary: model.summary,
            calendar: calendar
        )
    }

    private var dateHeaderText: String {
        todayClock.referenceDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var body: some View {
        // Resolved once per render (the budget figures are a full-window recompute).
        let budgetModel = BudgetCalculator.cardModel(
            budget: budgets.first,
            allTransactions: transactions,
            isAccountBackfillComplete: importService?.isAccountBackfillComplete ?? true,
            referenceDate: todayClock.referenceDate,
            calendar: calendar
        )

        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if let budgetModel {
                        BudgetHeroCardView(
                            state: budgetModel.state,
                            summary: budgetModel.summary,
                            insights: budgetInsights(budgetModel),
                            onChooseAccounts: { tabSelection.selected = .goals }
                        )
                    }

                    ForEach(completedGoals, id: \.persistentModelID) { goal in
                        CompletionBannerView(goal: goal) {
                            dismiss(goal)
                        }
                    }

                    if let summary {
                        // Titled only when the budget card is also showing, so a
                        // savings-only Today is unchanged.
                        HeroSection(summary: summary, title: budgetModel == nil ? nil : "Savings limit")
                        TwoStatRow(summary: summary)
                    } else if hasNoGoalsAtAll {
                        // A budget with no goal needs no goal prompt: the budget card is
                        // the whole story.
                        if budgetModel == nil {
                            NoActiveGoalPromptView {
                                isShowingCreateGoal = true
                            }
                            Button("Or set a monthly budget instead.") {
                                isShowingCreateBudget = true
                            }
                            .font(.subheadline)
                            .foregroundStyle(Color("ReservoirTextSecondary"))
                            .accessibilityIdentifier("today.setBudgetLink")
                        }
                    } else {
                        // A completed-but-undismissed goal exists (its banner is already
                        // shown above) but there's no active goal, so there's no daily
                        // limit to show. Still surface today's spend rather than letting
                        // it disappear from the screen — see TodayScreenCalculator.
                        SpentTodayOnlyCard(amount: spentTodayWithoutActiveGoal)
                    }

                    RecentTransactionsSection(transactions: recentTransactions)

                    Button {
                        isShowingAddTransaction = true
                    } label: {
                        Text("Add transaction")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ReservoirPrimaryButtonStyle())
                    .accessibilityIdentifier("today.addTransaction")
                }
                .padding()
            }
            .background(Color("ReservoirBackground"))
            // Pinned just above the tab bar so it stays visible without scrolling.
            .safeAreaInset(edge: .bottom) {
                DataFreshnessLabel(
                    lastSync: importService?.lastSuccessfulSync,
                    transactions: transactions,
                    now: todayClock.referenceDate,
                    identifier: "today.dataFreshness",
                    isCentered: true
                )
                .padding(.horizontal)
                .padding(.vertical, 6)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .background(Color("ReservoirBackground"))
            }
            .navigationTitle(dateHeaderText)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CategoryBreakdownView()
                    } label: {
                        Image(systemName: "chart.pie")
                    }
                    .accessibilityLabel("Spending by category")
                    .accessibilityIdentifier("today.spendingByCategory")
                }
            }
        }
        .sheet(isPresented: $isShowingAddTransaction) {
            TransactionEntryView(mode: .create, accessibilityIdentifier: "today.addTransactionSheet")
        }
        .sheet(isPresented: $isShowingCreateGoal) {
            GoalFormView(mode: .create, accessibilityIdentifier: "today.createGoalSheet")
        }
        .sheet(isPresented: $isShowingCreateBudget) {
            BudgetFormView(mode: .create, accessibilityIdentifier: "today.createBudgetSheet")
        }
        .saveErrorAlert($dismissError)
    }

    /// Dismissing a completion banner resets the goal to a true empty/no-goal state:
    /// once `dismissedAt` is set, `TodayScreenCalculator.isActive` and
    /// `completedUndismissedGoals` both exclude it permanently, so the Today screen
    /// falls back to the "no active goal" empty state until the user creates a new one.
    ///
    /// If the save fails, the in-memory `dismissedAt` is rolled back rather than left
    /// set-but-unpersisted — otherwise the banner would silently vanish for the rest of
    /// this session (SwiftData's in-memory state already reflects the mutation) while
    /// reappearing on next launch with no indication anything went wrong. The error is
    /// both logged and surfaced via an alert so a persistent failure (e.g. a full disk)
    /// doesn't fail silently.
    private func dismiss(_ goal: SavingsGoal) {
        dismissError = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { goal.dismissedAt = .now },
            rollback: { goal.dismissedAt = nil },
            logger: logger
        )
    }

}

// `HeroSection`/`TwoStatRow`/`StatCard` moved to `Reservoir/Shared/HeroSection.swift`
// (reservoir-j8t) so the monthly-budget card reuses them (STANDARDS.md §3).

/// Shown in place of `HeroSection`/`TwoStatRow` when there's no active goal (so no
/// daily limit is defined) but there's still today's spend worth surfacing — e.g. every
/// goal is completed-but-undismissed. See `TodayView.spentTodayWithoutActiveGoal`.
private struct SpentTodayOnlyCard: View {
    let amount: Decimal

    var body: some View {
        StatCard(title: "Spent today", amount: amount, isOverLimit: false)
            // .contain, matching HeroSection/TwoStatRow, so this stays queryable as its
            // own "Other" element in XCUITest instead of being auto-flattened.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("today.spentTodayOnly")
    }
}

// §3.5's primary button — moved to `Reservoir/Shared/ReservoirPrimaryButtonStyle.swift`
// (reservoir-jog) once Goals/Transactions/Settings needed the identical CTA treatment;
// see that file's doc comment for the full rationale (STANDARDS.md §3, no copy-paste).

// MARK: - Completion banner

// MARK: - Recent transactions

private struct RecentTransactionsSection: View {
    let transactions: [SpendTransaction]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent transactions")
                .font(.headline)

            if transactions.isEmpty {
                Text("No transactions yet.")
                    .font(.subheadline)
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("today.emptyTransactions")
            } else {
                ForEach(transactions, id: \.persistentModelID) { transaction in
                    TransactionRowView(transaction: transaction, showDate: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.recentTransactions")
    }
}

// `TransactionRow` moved to `Reservoir/Shared/TransactionRowView.swift` (code review on
// feat/transactions) so `TodayView`/`TransactionsView` share one row implementation
// instead of two near-identical copies (STANDARDS.md §3).
