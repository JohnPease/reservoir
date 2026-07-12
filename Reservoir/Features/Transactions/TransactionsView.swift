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
                                        TransactionListRow(transaction: transaction)
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
        .sheet(
            isPresented: Binding(
                get: { transactionPendingEdit != nil },
                set: { isPresented in if !isPresented { transactionPendingEdit = nil } }
            )
        ) {
            if let transaction = transactionPendingEdit {
                TransactionEntryView(mode: .edit(transaction), accessibilityIdentifier: "transactions.editTransactionSheet")
            }
        }
        .confirmationDialog(
            "Delete this transaction? This can't be undone.",
            isPresented: Binding(
                get: { transactionPendingDelete != nil },
                set: { isPresented in if !isPresented { transactionPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let transaction = transactionPendingDelete { delete(transaction) }
                transactionPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { transactionPendingDelete = nil }
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { actionError != nil },
                set: { isPresented in if !isPresented { actionError = nil } }
            ),
            presenting: actionError
        ) { _ in
            Button("OK") { actionError = nil }
        } message: { message in
            Text(message)
        }
    }

    private func delete(_ transaction: SpendTransaction) {
        actionError = PersistenceSaveHelper.saveOrRollback(
            modelContext: modelContext,
            mutate: { modelContext.delete(transaction) },
            rollback: { modelContext.insert(transaction) },
            logger: logger
        )
    }
}

// MARK: - Row

private struct TransactionListRow: View {
    let transaction: SpendTransaction

    private var isFixed: Bool { transaction.type == .fixed }

    private var goalLabel: String {
        transaction.savingsGoal?.displayName ?? "Unattributed"
    }

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
                Text(goalLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transactions.row.goalLabel")
            }

            Spacer()

            Text(transaction.amount, format: .currency(code: "USD"))
                .foregroundStyle(isFixed ? .secondary : .primary)
        }
        .opacity(isFixed ? 0.6 : 1.0)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transactions.row")
    }
}
