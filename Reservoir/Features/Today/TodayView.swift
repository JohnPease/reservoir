import SwiftUI
import SwiftData
import OSLog

/// The Today tab — the app's launch screen and the home of the core mechanic. Layout
/// per `docs/PROJECT_SPEC.md` "UX design — Today screen": date header with settings
/// icon, hero daily-limit number, two-stat row, recent transactions, single "Add
/// transaction" primary action.
///
/// All calculation (goal lifecycle, the `SavingsGoal`/`SpendTransaction` ->
/// `GoalCarryForwardInput` mapping, the spent/remaining summary) lives in
/// `TodayScreenCalculator`, not here — this view only lays things out and reacts to
/// state changes (STANDARDS.md §3).
struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @Query(sort: \SavingsGoal.targetDate) private var goals: [SavingsGoal]
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

    /// "Now," recomputed on foreground resume and at the next midnight rollover so the
    /// hero number, active-goal set, and completion banners stay correct without
    /// requiring the user to relaunch. Not itself business logic — just the clock input
    /// to `TodayScreenCalculator`.
    @State private var referenceDate: Date = .now

    @State private var isShowingAddTransaction = false
    @State private var isShowingCreateGoal = false
    @State private var isShowingSettings = false
    @State private var dismissError: String?

    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "TodayView")

    private var activeGoals: [SavingsGoal] {
        TodayScreenCalculator.activeGoals(goals, referenceDate: referenceDate, calendar: calendar)
    }

    private var completedGoals: [SavingsGoal] {
        TodayScreenCalculator.completedUndismissedGoals(goals, referenceDate: referenceDate, calendar: calendar)
    }

    private var summary: TodayScreenCalculator.Summary? {
        TodayScreenCalculator.summary(
            activeGoals: activeGoals,
            completedUndismissedGoals: completedGoals,
            allTransactions: transactions,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    /// True only when there is truly nothing to show for goals — no active goal and no
    /// completed-but-undismissed goal either. Distinct from `summary == nil`, which is
    /// also true whenever there's no active goal even if a completion banner is showing;
    /// using that alone to gate the empty-state prompt made the prompt render underneath
    /// a completion banner, which is a real (fixed) bug — see `TodayScreenCalculator`.
    private var hasNoGoalsAtAll: Bool {
        activeGoals.isEmpty && completedGoals.isEmpty
    }

    /// Today's spend attributable to a completed-but-undismissed goal or unattributed
    /// entirely, for display when there's no active goal (so `summary` is `nil` and the
    /// hero/two-stat row aren't shown) but that spend still shouldn't disappear from the
    /// screen.
    private var spentTodayWithoutActiveGoal: Decimal {
        TodayScreenCalculator.spentToday(
            allTransactions: transactions,
            attributedGoals: completedGoals,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    private var recentTransactions: [SpendTransaction] {
        recentTransactionsQuery
    }

    private var dateHeaderText: String {
        referenceDate.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ForEach(completedGoals, id: \.persistentModelID) { goal in
                        CompletionBannerView(goal: goal) {
                            dismiss(goal)
                        }
                    }

                    if let summary {
                        HeroSection(summary: summary)
                        TwoStatRow(summary: summary)
                    } else if hasNoGoalsAtAll {
                        NoActiveGoalPromptView {
                            isShowingCreateGoal = true
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
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("today.addTransaction")
                }
                .padding()
            }
            .navigationTitle(dateHeaderText)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityIdentifier("today.settings")
                }
            }
        }
        .onAppear { referenceDate = .now }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { referenceDate = .now }
        }
        .task { await scheduleMidnightRefresh() }
        .sheet(isPresented: $isShowingAddTransaction) {
            StubSheet(
                title: "Add Transaction",
                icon: "plus.circle",
                description: "Manual transaction entry is coming in a future story.",
                accessibilityIdentifier: "today.addTransactionSheet"
            )
        }
        .sheet(isPresented: $isShowingCreateGoal) {
            GoalFormView(mode: .create, accessibilityIdentifier: "today.createGoalSheet")
        }
        .sheet(isPresented: $isShowingSettings) {
            StubSheet(
                title: "Settings",
                icon: "gearshape",
                description: "Settings are coming in a future story.",
                accessibilityIdentifier: "today.settingsSheet"
            )
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { dismissError != nil },
                set: { isPresented in if !isPresented { dismissError = nil } }
            ),
            presenting: dismissError
        ) { _ in
            Button("OK") { dismissError = nil }
        } message: { message in
            Text(message)
        }
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

    /// Recomputes `referenceDate` at every midnight boundary while the view is alive,
    /// so a long-lived foreground session (app left open overnight) still rolls the
    /// daily limit over without needing a foreground-resume event.
    private func scheduleMidnightRefresh() async {
        while !Task.isCancelled {
            let now = Date()
            let nextMidnight = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            ) ?? now.addingTimeInterval(86_400)

            let nanoseconds = UInt64(max(nextMidnight.timeIntervalSince(now), 1)) * 1_000_000_000
            try? await Task.sleep(nanoseconds: nanoseconds)

            guard !Task.isCancelled else { return }
            referenceDate = .now
        }
    }
}

// MARK: - Hero

private struct HeroSection: View {
    let summary: TodayScreenCalculator.Summary

    var body: some View {
        VStack(spacing: 4) {
            // 44px per PROJECT_SPEC's "UX design — Today screen" — a manual/code-review
            // check (STANDARDS.md §5), not something asserted in XCUITest.
            Text(summary.limit, format: .currency(code: "USD"))
                .font(.system(size: 44, weight: .bold))
                .accessibilityIdentifier("today.heroAmount")

            Text("\(currency(summary.dailyBase)) base + \(currency(summary.carriedForward)) carried forward")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        // .contain, not the default .automatic, so this stays queryable as its own
        // "Other" element in XCUITest instead of being auto-flattened into a StaticText
        // that swallows the identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.hero")
    }

    private func currency(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "USD"))
    }
}

// MARK: - Two-stat row

private struct TwoStatRow: View {
    let summary: TodayScreenCalculator.Summary

    var body: some View {
        HStack(spacing: 16) {
            StatCard(title: "Spent today", amount: summary.spentToday, isOverLimit: false)
            StatCard(title: "Remaining", amount: summary.remaining, isOverLimit: summary.remaining < 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.stats")
    }
}

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

private struct StatCard: View {
    let title: String
    let amount: Decimal
    let isOverLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(amount, format: .currency(code: "USD"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(isOverLimit ? .red : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

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
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("today.emptyTransactions")
            } else {
                ForEach(transactions, id: \.persistentModelID) { transaction in
                    TransactionRow(transaction: transaction)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.recentTransactions")
    }
}

private struct TransactionRow: View {
    let transaction: SpendTransaction

    private var isFixed: Bool { transaction.type == .fixed }

    var body: some View {
        HStack {
            Image(systemName: isFixed ? "lock.fill" : "cart.fill")
                .foregroundStyle(isFixed ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(transaction.merchantName)
                    .foregroundStyle(isFixed ? .secondary : .primary)
                if isFixed {
                    Text("Excluded from limit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(transaction.date, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text(transaction.amount, format: .currency(code: "USD"))
                .foregroundStyle(isFixed ? .secondary : .primary)
        }
        .opacity(isFixed ? 0.6 : 1.0)
    }
}
