import SwiftUI
import SwiftData

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

    @Query private var goals: [SavingsGoal]
    @Query private var transactions: [SpendTransaction]

    /// "Now," recomputed on foreground resume and at the next midnight rollover so the
    /// hero number, active-goal set, and completion banners stay correct without
    /// requiring the user to relaunch. Not itself business logic — just the clock input
    /// to `TodayScreenCalculator`.
    @State private var referenceDate: Date = .now

    @State private var isShowingAddTransaction = false
    @State private var isShowingCreateGoal = false
    @State private var isShowingSettings = false

    private let calendar: Calendar = .current

    private var activeGoals: [SavingsGoal] {
        TodayScreenCalculator.activeGoals(goals, referenceDate: referenceDate, calendar: calendar)
    }

    private var completedGoals: [SavingsGoal] {
        TodayScreenCalculator.completedUndismissedGoals(goals, referenceDate: referenceDate, calendar: calendar)
    }

    private var summary: TodayScreenCalculator.Summary? {
        TodayScreenCalculator.summary(
            activeGoals: activeGoals,
            allTransactions: transactions,
            referenceDate: referenceDate,
            calendar: calendar
        )
    }

    private var recentTransactions: [SpendTransaction] {
        TodayScreenCalculator.recentTransactions(from: transactions)
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
                    } else {
                        NoActiveGoalPrompt {
                            isShowingCreateGoal = true
                        }
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
        .sheet(isPresented: $isShowingAddTransaction) { AddTransactionStubSheet() }
        .sheet(isPresented: $isShowingCreateGoal) { CreateGoalStubSheet() }
        .sheet(isPresented: $isShowingSettings) { SettingsStubSheet() }
    }

    /// Dismissing a completion banner resets the goal to a true empty/no-goal state:
    /// once `dismissedAt` is set, `TodayScreenCalculator.isActive` and
    /// `completedUndismissedGoals` both exclude it permanently, so the Today screen
    /// falls back to the "no active goal" empty state until the user creates a new one.
    private func dismiss(_ goal: SavingsGoal) {
        goal.dismissedAt = .now
        try? modelContext.save()
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

// MARK: - Empty state

private struct NoActiveGoalPrompt: View {
    let onCreateGoal: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "target")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No active goal yet")
                .font(.headline)
            Text("Create a savings goal to see your daily limit.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create a goal", action: onCreateGoal)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("today.createGoal")
        }
        .frame(maxWidth: .infinity)
        .padding()
        // .contain keeps "today.createGoal" queryable on the Button itself instead of
        // the whole group collapsing into one element under the container's identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.emptyGoalState")
    }
}

// MARK: - Completion banner

private struct CompletionBannerView: View {
    let goal: SavingsGoal
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Goal complete!")
                    .font(.headline)
                Text("You reached your target of \(goal.targetAmount, format: .currency(code: "USD")). Nice work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityIdentifier("today.dismissBanner")
        }
        .padding()
        .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.completionBanner")
    }
}

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
