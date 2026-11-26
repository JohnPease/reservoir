import Foundation
import SwiftData

/// Month-local budget insights (reservoir-j8t PR3): a pace sentence, an end-of-month
/// projection, and a per-account breakdown, all resolved here into one `BudgetInsights`
/// value so views only render. Imports SwiftData for the model types only (STANDARDS.md
/// §4's `*Calculator` exception); never SwiftUI. Pure functions of (budget, transactions,
/// reference date, linked accounts/items) — nothing is persisted.
///
/// Recovery and month warnings (reservoir-nka.1) come from `BudgetRecoveryCalculator` when the
/// caller opts in (`includeRecovery`), and the carry-mode projection text counts the carry into
/// the month. Everything else is month-local.
///
/// Month-local definitions (the same in carry and reset mode; only the carry-mode projection
/// text and the recovery warnings add the carry `C` on top of them):
/// - `windowStart` = the later of the 1st of the reference month and `budget.startDate`.
/// - `e` = days from `windowStart` through today, inclusive.
/// - `spent` = counted spend (`BudgetCalculator.countsTowardBudget`) in that window.
/// - `budgetedToDate` = sum of `BaseSchedule.base(on:)` over those days.
/// - `paceDelta` = `budgetedToDate - spent` (positive = under pace).
enum BudgetSummaryCalculator {

    /// The projection stays hidden until this many days of the window have fully
    /// elapsed; earlier it is dominated by one or two big purchases.
    static let projectionMinimumCompletedDays = 7

    /// A pace/projection difference smaller than this many dollars reads "right on".
    static let rightOnTolerance: Decimal = 1

    // MARK: - Output types

    /// A sentence in three parts so a view can color one phrase: `lead + deficitPhrase + tail`.
    /// The progress sentence is fully neutral (reservoir-nka.1) and never sets `deficitPhrase`;
    /// the Today recovery banner reuses this shape and sets it only for its point-of-no-return
    /// line (`BudgetRecoveryCalculator`).
    struct ProgressSentence: Codable, Equatable {
        var lead: String
        var deficitPhrase: String?
        var tail: String

        var text: String { lead + (deficitPhrase ?? "") + tail }
    }

    struct Projection: Codable, Equatable {
        /// Spend through yesterday divided by completed days in the window.
        var dailyRate: Decimal
        var projectedMonthTotal: Decimal
        /// Budget for the window (monthly amount for a full month).
        var windowBudget: Decimal
        /// Month-local: `windowBudget - projectedMonthTotal`. Positive = projected under budget.
        var projectedDelta: Decimal
        /// The carry the month started with (`BudgetRecoveryCalculator.carryIn`); 0 in reset mode.
        var carryIn: Decimal
        /// What the month is heading to finish at counting the carry: `projectedDelta + carryIn`
        /// (equal to `projectedDelta` in reset mode). Positive = under. `text` reads this.
        var finishDelta: Decimal
        var text: String
    }

    struct AccountRow: Codable, Equatable {
        var accountID: String
        /// "Name ••mask", "Unknown account", or "Removed account".
        var title: String
        var spent: Decimal
        var needsRelink: Bool
        var isRemoved: Bool
    }

    struct Breakdown: Codable, Equatable {
        var rows: [AccountRow]
        /// "N account(s) no longer linked." when any row is removed.
        var unlinkedCaption: String?
    }

    /// Month-to-date result (not consumed by the widget, which reads `spent` and the progress
    /// sentence instead). Completed months are reviewed by
    /// `BudgetMonthReviewCalculator`. Not persisted anywhere.
    struct MonthResult: Codable, Equatable {
        var budgeted: Decimal
        var spent: Decimal
        /// `budgeted - spent` (positive = under pace).
        var delta: Decimal
        /// Carry into next month: today's remaining in carry mode, 0 in reset mode.
        var endingCarry: Decimal
    }

    struct BudgetInsights: Codable, Equatable {
        var dayOfMonth: Int
        var daysInMonth: Int
        /// Set when the budget started mid-month, so the window is shorter than the month.
        var trackingSince: Date?
        var spent: Decimal
        var budgetedToDate: Decimal
        var paceDelta: Decimal
        var sentence: ProgressSentence
        var projection: Projection?
        /// `nil` when hidden (a single selected account).
        var breakdown: Breakdown?
        var monthResult: MonthResult
        /// No-spend days to recover, the month warning, and the Today banner (reservoir-nka.1).
        /// `nil` unless the caller passed `includeRecovery: true` (Today and the widget do;
        /// Plans doesn't).
        var recovery: BudgetRecoveryCalculator.Result?
    }

    // MARK: - Entry point

    /// `nil` when there is no budget, the card isn't `.active` (syncing / no accounts), or
    /// the budget hasn't started yet.
    ///
    /// - Parameters:
    ///   - summary: optional, to avoid a second full-window recompute. Precondition: it must be
    ///     `BudgetCalculator.summary` for this same budget, `transactions`, `referenceDate` and
    ///     `calendar` (every caller passes its `cardModel(...).summary` from the same render).
    ///     The carry in (`remaining - paceDelta`) is only exact under that identity; a summary
    ///     cached across midnight or a transaction change would silently skew it.
    ///   - includeRecovery: run `BudgetRecoveryCalculator` (a lookback over counted spend) and
    ///     fill `BudgetInsights.recovery`. Off by default; Today and the widget ask for it.
    ///     The carry in for the projection is computed either way.
    static func insights(
        budget: Budget?,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        linkedAccounts: [LinkedAccount],
        linkedItems: [LinkedItem],
        summary: TodayScreenCalculator.Summary? = nil,
        includeRecovery: Bool = false,
        calendar: Calendar = .current
    ) -> BudgetInsights? {
        guard let budget,
              BudgetCalculator.cardState(for: budget, isAccountBackfillComplete: isAccountBackfillComplete) == .active
        else { return nil }

        let today = calendar.startOfDay(for: referenceDate)
        guard let monthStart = calendar.dateInterval(of: .month, for: today)?.start,
              let daysInMonth = calendar.range(of: .day, in: .month, for: today)?.count
        else { return nil }
        let windowStart = max(monthStart, calendar.startOfDay(for: budget.startDate))
        guard windowStart <= today else { return nil }

        let dayOfMonth = calendar.component(.day, from: today)
        let elapsedDays = (calendar.dateComponents([.day], from: windowStart, to: today).day ?? 0) + 1
        let schedule = BaseSchedule.monthly(budget.monthlyAmount)

        let selected = Set(budget.selectedAccountIDs)
        let tomorrow = BudgetCalculator.nextDayStart(after: today, calendar: calendar)
        let counted = transactions.filter {
            BudgetCalculator.countsTowardBudget($0, selectedAccountIDs: selected, startDay: windowStart)
                && $0.date < tomorrow
        }
        let spent = counted.reduce(Decimal(0)) { $0 + $1.amount }
        let spentToday = counted.reduce(Decimal(0)) {
            $1.date >= today ? $0 + $1.amount : $0
        }

        let budgetedToDate = baseSum(schedule, from: windowStart, days: elapsedDays, calendar: calendar)
        let paceDelta = budgetedToDate - spent
        let trackingSince = windowStart > monthStart ? windowStart : nil

        let resolvedSummary = summary ?? BudgetCalculator.summary(
            budget: budget, allTransactions: transactions, referenceDate: referenceDate, calendar: calendar
        )

        // The budget for the window (the monthly amount for a full month; the sum of daily
        // bases from a mid-month start). The over-budget sentence and the projection both
        // compare against this, so they can never disagree.
        let windowBudget = baseSum(
            schedule, from: windowStart, days: daysInMonth - calendar.component(.day, from: windowStart) + 1, calendar: calendar
        )

        let sentence = progressSentence(
            dayOfMonth: dayOfMonth,
            daysInMonth: daysInMonth,
            trackingSince: trackingSince,
            elapsedDays: elapsedDays,
            spent: spent,
            windowBudget: windowBudget,
            paceDelta: paceDelta,
            firstOfMonthCarry: dayOfMonth == 1 ? firstOfMonthClause(budget: budget, carry: resolvedSummary?.carriedForward ?? 0) : nil,
            calendar: calendar
        )

        let remaining = resolvedSummary?.remaining ?? paceDelta
        let boundary: MonthBoundary = budget.carriesAcrossMonths ? .carry : .reset
        let carryIn = BudgetRecoveryCalculator.carryIn(remaining: remaining, paceDelta: paceDelta, boundary: boundary)

        let projection = projection(
            elapsedDays: elapsedDays,
            dayOfMonth: dayOfMonth,
            daysInMonth: daysInMonth,
            spent: spent,
            spentToday: spentToday,
            windowBudget: windowBudget,
            carryIn: budget.carriesAcrossMonths ? carryIn : nil,
            monthName: BudgetRecoveryCalculator.monthName(today, calendar: calendar)
        )

        let recovery = includeRecovery ? BudgetRecoveryCalculator.result(
            BudgetRecoveryCalculator.Input(
                monthlyAmount: budget.monthlyAmount,
                monthBoundary: boundary,
                today: today,
                remaining: remaining,
                spent: spent,
                windowBudget: windowBudget,
                paceDelta: paceDelta,
                projectedDelta: projection?.projectedDelta,
                dayOfMonth: dayOfMonth,
                daysInMonth: daysInMonth,
                spentByDay: BudgetCalculator.countedSpendByDay(transactions, for: budget, calendar: calendar),
                budgetStartDay: calendar.startOfDay(for: budget.startDate)
            ),
            calendar: calendar
        ) : nil

        let breakdown = breakdown(
            budget: budget,
            counted: counted,
            allTransactions: transactions,
            linkedAccounts: linkedAccounts,
            linkedItems: linkedItems
        )

        let endingCarry = budget.carriesAcrossMonths ? (resolvedSummary?.remaining ?? 0) : 0
        return BudgetInsights(
            dayOfMonth: dayOfMonth,
            daysInMonth: daysInMonth,
            trackingSince: trackingSince,
            spent: spent,
            budgetedToDate: budgetedToDate,
            paceDelta: paceDelta,
            sentence: sentence,
            projection: projection,
            breakdown: breakdown,
            monthResult: MonthResult(budgeted: budgetedToDate, spent: spent, delta: paceDelta, endingCarry: endingCarry),
            recovery: recovery
        )
    }

    /// Same as above, reading accounts/items from their stores (what both budget cards
    /// call, so the store lookup isn't repeated per view).
    static func insights(
        budget: Budget?,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        accountStore: LinkedAccountStoring = LinkedAccountStore(),
        itemStore: LinkedItemStoring = LinkedItemStore(),
        summary: TodayScreenCalculator.Summary? = nil,
        includeRecovery: Bool = false,
        calendar: Calendar = .current
    ) -> BudgetInsights? {
        guard budget != nil else { return nil }
        return insights(
            budget: budget,
            transactions: transactions,
            isAccountBackfillComplete: isAccountBackfillComplete,
            referenceDate: referenceDate,
            linkedAccounts: accountStore.loadAll(),
            linkedItems: itemStore.loadAll(),
            summary: summary,
            includeRecovery: includeRecovery,
            calendar: calendar
        )
    }

    /// The card model and its insights (with recovery) from one pass, so the summary the
    /// insights consume is by construction the one for this budget, transactions, reference
    /// date and calendar (the precondition documented on `insights`). Used by the widget and
    /// the budget warning notifier. `insights` is `nil` when there is no budget or the card
    /// isn't `.active`.
    static func cardModelAndRecoveryInsights(
        budget: Budget?,
        transactions: [SpendTransaction],
        isAccountBackfillComplete: Bool,
        referenceDate: Date,
        accountStore: LinkedAccountStoring = LinkedAccountStore(),
        itemStore: LinkedItemStoring = LinkedItemStore(),
        calendar: Calendar = .current
    ) -> (model: BudgetCalculator.CardModel?, insights: BudgetInsights?) {
        let model = BudgetCalculator.cardModel(
            budget: budget,
            allTransactions: transactions,
            isAccountBackfillComplete: isAccountBackfillComplete,
            referenceDate: referenceDate,
            calendar: calendar
        )
        let insights = model.flatMap { model in
            insights(
                budget: budget,
                transactions: transactions,
                isAccountBackfillComplete: isAccountBackfillComplete,
                referenceDate: referenceDate,
                accountStore: accountStore,
                itemStore: itemStore,
                summary: model.summary,
                includeRecovery: true,
                calendar: calendar
            )
        }
        return (model, insights)
    }

    // MARK: - Sentence

    /// The clause appended on the 1st only; `nil` = nothing to append (carry of $0).
    static func firstOfMonthClause(budget: Budget, carry: Decimal) -> String? {
        guard budget.carriesAcrossMonths else { return " Fresh month, nothing carried over." }
        let rounded = wholeDollars(carry)
        if rounded > 0 { return " \(whole(carry)) carried over from last month." }
        if rounded < 0 { return " Starting \(whole(-carry)) in the hole from last month." }
        return nil
    }

    static func progressSentence(
        dayOfMonth: Int,
        daysInMonth: Int,
        trackingSince: Date?,
        elapsedDays: Int,
        spent: Decimal,
        windowBudget: Decimal,
        paceDelta: Decimal,
        firstOfMonthCarry: String?,
        calendar: Calendar
    ) -> ProgressSentence {
        var prefix = "Day \(dayOfMonth) of \(daysInMonth)"
        if let trackingSince {
            prefix += " (tracking since \(monthDay(trackingSince, calendar: calendar)))"
        }
        prefix += ". "
        let clause = firstOfMonthCarry ?? ""

        // "Over" only when the overage would round to at least $1; a few cents over reads
        // as the ordinary pace sentence instead of "$0 over". `windowBudget` is the whole
        // monthly amount for a full month, or the prorated window budget for a mid-month
        // start, whose copy says "period" because the budget isn't the full month's.
        // Fully neutral (reservoir-nka.1): no phrase is set apart for coloring.
        if isOver(by: spent - windowBudget) {
            return ProgressSentence(
                lead: prefix + "You've spent \(whole(spent)) of your \(whole(windowBudget)) budget" + (trackingSince == nil ? ", " : " for this period, ")
                    + "\(whole(spent - windowBudget)) over" + (trackingSince == nil ? " for the month" : "") + "." + clause,
                deficitPhrase: nil,
                tail: ""
            )
        }
        if spent == 0 && elapsedDays == 1 {
            return ProgressSentence(lead: prefix + "No spending yet this month.", deficitPhrase: nil, tail: clause)
        }
        let lead = prefix + "You've spent \(whole(spent)), "
        if abs(paceDelta) < rightOnTolerance {
            return ProgressSentence(lead: lead + "right on pace.", deficitPhrase: nil, tail: clause)
        }
        if paceDelta > 0 {
            return ProgressSentence(lead: lead + "about \(whole(paceDelta)) under pace.", deficitPhrase: nil, tail: clause)
        }
        return ProgressSentence(lead: lead + "about \(whole(-paceDelta)) over pace." + clause, deficitPhrase: nil, tail: "")
    }

    // MARK: - Projection

    private static func projection(
        elapsedDays: Int,
        dayOfMonth: Int,
        daysInMonth: Int,
        spent: Decimal,
        spentToday: Decimal,
        windowBudget: Decimal,
        carryIn: Decimal?,
        monthName: String
    ) -> Projection? {
        let completedDays = elapsedDays - 1
        guard completedDays >= projectionMinimumCompletedDays, dayOfMonth < daysInMonth else { return nil }

        let rate = (spent - spentToday) / Decimal(completedDays)
        let projected = spent + rate * Decimal(daysInMonth - dayOfMonth)
        let delta = windowBudget - projected
        let finish = delta + (carryIn ?? 0)
        return Projection(
            dailyRate: rate, projectedMonthTotal: projected, windowBudget: windowBudget, projectedDelta: delta,
            carryIn: carryIn ?? 0, finishDelta: finish,
            text: projectionText(finishDelta: finish, carryIn: carryIn, monthName: monthName)
        )
    }

    /// Reset mode (`carryIn == nil`): the month-local wording. Carry mode counts the carry the
    /// month started with, in the month warning's style.
    static func projectionText(finishDelta: Decimal, carryIn: Decimal?, monthName: String) -> String {
        guard let carryIn else {
            if abs(finishDelta) < rightOnTolerance { return "At this pace you'll finish right on budget." }
            if finishDelta > 0 { return "At this pace you'll finish about \(whole(finishDelta)) under budget." }
            return "At this pace you'll finish about \(whole(-finishDelta)) over budget."
        }
        let clause = BudgetRecoveryCalculator.carryClause(carryIn)
        let counting = clause.isEmpty ? "" : "," + clause
        if abs(finishDelta) < rightOnTolerance { return "At this pace you'll finish \(monthName) even\(counting)." }
        if finishDelta > 0 { return "At this pace you'll finish \(monthName) about \(whole(finishDelta)) under\(counting)." }
        return "At this pace you'll finish \(monthName) about \(whole(-finishDelta)) over\(counting)."
    }

    // MARK: - Breakdown

    static let unknownAccountTitle = "Unknown account"
    static let removedAccountTitle = "Removed account"

    private static func breakdown(
        budget: Budget,
        counted: [SpendTransaction],
        allTransactions: [SpendTransaction],
        linkedAccounts: [LinkedAccount],
        linkedItems: [LinkedItem]
    ) -> Breakdown? {
        guard budget.selectedAccountIDs.count > 1 else { return nil }

        let accountsByID = Dictionary(linkedAccounts.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
        let itemsByID = Dictionary(linkedItems.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        var spendByAccount: [String: Decimal] = [:]
        for transaction in counted {
            if let id = transaction.plaidAccountID { spendByAccount[id, default: 0] += transaction.amount }
        }

        let rows = budget.selectedAccountIDs.map { accountID -> AccountRow in
            let spent = spendByAccount[accountID] ?? 0
            if let account = accountsByID[accountID] {
                let title = account.mask.map { "\(account.name) ••\($0)" } ?? account.name
                return AccountRow(
                    accountID: accountID, title: title, spent: spent,
                    needsRelink: itemsByID[account.itemID]?.needsAttention ?? false, isRemoved: false
                )
            }
            // Not cached: "Unknown" if one of its transactions still belongs to a linked
            // item (metadata just hasn't synced), "Removed" otherwise.
            let stillLinked = allTransactions.contains {
                $0.plaidAccountID == accountID && $0.plaidItemID.map { itemsByID[$0] != nil } == true
            }
            return AccountRow(
                accountID: accountID,
                title: stillLinked ? unknownAccountTitle : removedAccountTitle,
                spent: spent, needsRelink: false, isRemoved: !stillLinked
            )
        }.sorted {
            if $0.spent != $1.spent { return $0.spent > $1.spent }
            if $0.title != $1.title { return $0.title < $1.title }
            return $0.accountID < $1.accountID
        }

        let removedCount = rows.filter(\.isRemoved).count
        let caption = removedCount == 0 ? nil : "\(removedCount) \(removedCount == 1 ? "account" : "accounts") no longer linked."
        return Breakdown(rows: rows, unlinkedCaption: caption)
    }

    // MARK: - Helpers

    /// Sum of the daily bases over `days` days from `start` (crossing month ends exactly).
    static func baseSum(_ schedule: BaseSchedule, from start: Date, days: Int, calendar: Calendar) -> Decimal {
        guard days > 0 else { return 0 }
        return (0..<days).reduce(Decimal(0)) { total, offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return total }
            return total + schedule.base(on: day, calendar: calendar)
        }
    }

    /// Whether an overage reads as "over": at least `rightOnTolerance`, so a few cents over is
    /// never "$0 over". Shared by the progress sentence and the point-of-no-return warning.
    static func isOver(by overage: Decimal) -> Bool {
        overage >= rightOnTolerance
    }

    /// `amount` rounded to whole dollars (`NSDecimalRound`, scale 0). `.plain` (the default)
    /// rounds half away from zero, matching `whole(_:)`'s copy. `.down` rounds toward negative
    /// infinity and is only used for non-negative "keep to" amounts, where rounding up could
    /// tell someone they can spend a few cents more than they can.
    static func wholeDollars(_ amount: Decimal, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, mode)
        return rounded
    }

    /// Whole-dollar USD, e.g. "$1,240" (en_US so copy and tests don't vary by device locale).
    static func whole(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter.string(from: amount as NSDecimalNumber) ?? "$\(amount)"
    }

    static func monthDay(_ date: Date, calendar: Calendar) -> String {
        formatted(date, "MMM d", calendar: calendar)
    }

    /// en_US date copy in `calendar`'s zone, so copy and tests don't vary by device locale.
    static func formatted(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
