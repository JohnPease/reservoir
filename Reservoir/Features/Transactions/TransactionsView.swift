import SwiftUI
import SwiftData
import OSLog

/// The Transactions tab (adq.3): day-grouped, date-descending list of every
/// `SpendTransaction`, an All/Variable/Fixed filter, a "+" entry point (shares
/// `TransactionEntryView` with `TodayView`'s "Add transaction" button), tap-to-edit,
/// swipe-to-delete, and a nav link into `MerchantRulesView`. Filtering/day-grouping logic
/// lives in `TransactionsScreenCalculator`, not here (STANDARDS.md §3).
struct TransactionsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(TodayClock.self) private var todayClock

    /// Mirrors `TodayView`'s `@Query` sort convention (date desc, `createdAt` desc
    /// same-day tiebreak) so this list's ordering matches the rest of the app.
    @Query(
        sort: [
            SortDescriptor(\SpendTransaction.date, order: .reverse),
            SortDescriptor(\SpendTransaction.createdAt, order: .reverse)
        ]
    )
    private var transactions: [SpendTransaction]

    @State private var filter: TransactionsScreenCalculator.Filter = .all
    @State private var isShowingAddTransaction = false
    @State private var transactionPendingEdit: SpendTransaction?
    @State private var transactionPendingDelete: SpendTransaction?
    @State private var actionError: String?

    private let calendar: Calendar = .current
    private let logger = Logger(subsystem: "com.reservoir.app", category: "TransactionsView")

    private var filteredTransactions: [SpendTransaction] {
        TransactionsScreenCalculator.filtered(transactions, by: filter)
    }

    private var sections: [TransactionsScreenCalculator.DaySection] {
        TransactionsScreenCalculator.groupedByDay(filteredTransactions, calendar: calendar)
    }

    var body: some View {
        NavigationStack {
            Group {
                if transactions.isEmpty {
                    ContentUnavailableView(
                        "No transactions yet",
                        systemImage: "list.bullet",
                        description: Text("Add a transaction to get started.")
                    )
                    .accessibilityIdentifier("transactions.emptyState")
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(TransactionsScreenCalculator.sectionTitle(for: section.day, referenceDate: todayClock.referenceDate, calendar: calendar)) {
                                ForEach(section.transactions, id: \.persistentModelID) { transaction in
                                    Button {
                                        transactionPendingEdit = transaction
                                    } label: {
                                        TransactionRowView(
                                            transaction: transaction,
                                            showGoalLabel: true,
                                            accessibilityIdentifier: "transactions.row"
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            transactionPendingDelete = transaction
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("transactions.list")
                }
            }
            .navigationTitle("Transactions")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Filter", selection: $filter) {
                        ForEach(TransactionsScreenCalculator.Filter.allCases) { filterOption in
                            Text(filterOption.rawValue).tag(filterOption)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("transactions.filter")
                }
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        MerchantRulesView()
                    } label: {
                        Image(systemName: "tag")
                    }
                    .accessibilityIdentifier("transactions.merchantRulesLink")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAddTransaction = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("transactions.addTransaction")
                }
            }
        }
        .sheet(isPresented: $isShowingAddTransaction) {
            TransactionEntryView(mode: .create, accessibilityIdentifier: "transactions.addTransactionSheet")
        }
        .editSheet(pendingItem: $transactionPendingEdit) { transaction in
            TransactionEntryView(mode: .edit(transaction), accessibilityIdentifier: "transactions.editTransactionSheet")
        }
        .deleteConfirmation(
            pendingItem: $transactionPendingDelete,
            title: { _ in "Delete this transaction? This can't be undone." },
            onDelete: delete
        )
        .saveErrorAlert($actionError)
    }

    private func delete(_ transaction: SpendTransaction) {
        actionError = PersistenceSaveHelper.deleteWithRollback(
            transaction,
            modelContext: modelContext,
            logger: logger
        )
    }
}

// `TransactionListRow` moved to `Reservoir/Shared/TransactionRowView.swift` (code review
// on feat/transactions) so `TodayView`/`TransactionsView` share one row implementation
// instead of two near-identical copies (STANDARDS.md §3).
