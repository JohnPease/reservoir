import Foundation
import SwiftData

/// Business logic for the monthly budget (reservoir-j8t): decides which transactions
/// count, maps `Budget` + `SpendTransaction`s into the plain value type
/// `DailyLimitCalculator` operates on, and produces the same `Summary` the Today hero
/// consumes. Imports SwiftData for the model types only (STANDARDS.md §4's `*Calculator`
/// exception); never SwiftUI.
///
/// The budget has no revision history. Everything here is a pure function of (the
/// budget's *current* fields, the transactions, the reference date): editing the budget
/// recomputes the whole window from `startDate` as if the new settings had always applied.
enum BudgetCalculator {

    // MARK: - Which transactions count

    /// The single predicate for "does this transaction count toward the budget". A
    /// transaction counts only if it belongs to a selected Plaid account (manual rows and
    /// not-yet-backfilled rows have no account and so never count), isn't a fixed
    /// expense, and falls on or after `startDate`. Independent of savings goals — the same
    /// transaction may also count toward a goal.
    static func countsTowardBudget(
        _ transaction: SpendTransaction,
        selectedAccountIDs: Set<String>,
        startDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        countsTowardBudget(
            transaction, selectedAccountIDs: selectedAccountIDs, startDay: calendar.startOfDay(for: startDate)
        )
    }

    /// Same predicate with the start day already normalized, so a list filter pays for
    /// `startOfDay` once rather than twice per transaction. `date >= startDay` is exactly
    /// `startOfDay(date) >= startDay` for a day-start `startDay`.
    static func countsTowardBudget(
        _ transaction: SpendTransaction,
        selectedAccountIDs: Set<String>,
        startDay: Date
    ) -> Bool {
        guard let accountID = transaction.plaidAccountID,
              selectedAccountIDs.contains(accountID),
              transaction.type != .fixed
        else { return false }
        return transaction.date >= startDay
    }

    /// Convenience over `countsTowardBudget(_:selectedAccountIDs:startDate:)` for a whole
    /// budget; builds the selection set once per call site that filters a list.
    static func countingTransactions(
        _ transactions: [SpendTransaction],
        for budget: Budget,
        calendar: Calendar = .current
    ) -> [SpendTransaction] {
        let selected = Set(budget.selectedAccountIDs)
        guard !selected.isEmpty else { return [] }
        let startDay = calendar.startOfDay(for: budget.startDate)
        return transactions.filter {
            countsTowardBudget($0, selectedAccountIDs: selected, startDay: startDay)
        }
    }

    // MARK: - DailyLimitCalculator mapping

    /// `effectiveStartDate` is exactly `budget.startDate` — no `createdAt` floor (unlike
    /// goals): a budget's spend comes from imported history, so a back-dated start has
    /// real transactions to count.
    static func carryForwardInput(
        for budget: Budget,
        transactions: [SpendTransaction],
        calendar: Calendar = .current
    ) -> GoalCarryForwardInput {
        carryForwardInput(for: budget, counting: countingTransactions(transactions, for: budget, calendar: calendar))
    }

    private static func carryForwardInput(for budget: Budget, counting: [SpendTransaction]) -> GoalCarryForwardInput {
        GoalCarryForwardInput(
            id: budget.persistentModelID,
            schedule: .monthly(budget.monthlyAmount),
            monthBoundary: budget.carriesAcrossMonths ? .carry : .reset,
            effectiveStartDate: budget.startDate,
            spendEntries: counting.map {
                GoalCarryForwardInput.SpendEntry(date: $0.date, amount: $0.amount, kind: .variable)
            }
        )
    }

    // MARK: - Summary

    /// The budget hero's figures, in the same shape as the savings summary. `nil` when
    /// there is no budget. With an empty account selection the figures are all
    /// spend-free; callers gate on `cardState` first so that is never shown as "$0".
    static func summary(
        budget: Budget?,
        allTransactions: [SpendTransaction],
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> TodayScreenCalculator.Summary? {
        guard let budget else { return nil }
        let counting = countingTransactions(allTransactions, for: budget, calendar: calendar)
        let input = carryForwardInput(for: budget, counting: counting)
        let limit = DailyLimitCalculator.dailyLimit(for: input, asOf: referenceDate, calendar: calendar)

        let today = calendar.startOfDay(for: referenceDate)
        let tomorrow = nextDayStart(after: today, calendar: calendar)
        let spentToday = counting.reduce(Decimal(0)) { total, transaction in
            transaction.date >= today && transaction.date < tomorrow ? total + transaction.amount : total
        }
        return TodayScreenCalculator.Summary(
            dailyBase: limit.dailyBase,
            carriedForward: limit.carryForward,
            limit: limit.limit,
            spentToday: spentToday,
            remaining: limit.limit - spentToday
        )
    }

    /// Start of the day after `dayStart` (a day-start). `startOfDay(date) == dayStart` is
    /// exactly `dayStart <= date < nextDayStart(after: dayStart)`, which avoids a calendar
    /// call per transaction when bucketing a long list.
    static func nextDayStart(after dayStart: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: dayStart).map(calendar.startOfDay(for:)) ?? dayStart.addingTimeInterval(86_400)
    }

    // MARK: - Card state

    /// What a budget card (Today hero or Plans card) should show. Kept here so the copy
    /// and gating order live in pure Swift, not in views.
    enum CardState: Equatable {
        /// Account backfill still running: transactions can't be attributed to accounts.
        case syncing
        /// Budget exists but no account is selected (e.g. after unlinking the last one).
        case chooseAccounts
        case active

        var message: String? {
            switch self {
            case .syncing: return "Syncing account data..."
            case .chooseAccounts: return "Choose accounts"
            case .active: return nil
            }
        }
    }

    static func cardState(for budget: Budget, isAccountBackfillComplete: Bool) -> CardState {
        if !isAccountBackfillComplete { return .syncing }
        if budget.selectedAccountIDs.isEmpty { return .chooseAccounts }
        return .active
    }

    /// Everything a budget card renders, resolved in one place so the Today hero and the
    /// Plans card can't drift: the gating state, plus the figures only when `.active`
    /// (the 730-day loop isn't run while syncing or with no accounts selected).
    struct CardModel: Equatable {
        let state: CardState
        let summary: TodayScreenCalculator.Summary?
    }

    /// `nil` when there is no budget.
    static func cardModel(
        budget: Budget?,
        allTransactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> CardModel? {
        guard let budget else { return nil }
        let state = cardState(for: budget, isAccountBackfillComplete: isAccountBackfillComplete)
        guard state == .active else { return CardModel(state: state, summary: nil) }
        return CardModel(
            state: state,
            summary: summary(budget: budget, allTransactions: allTransactions, referenceDate: referenceDate, calendar: calendar)
        )
    }
}
