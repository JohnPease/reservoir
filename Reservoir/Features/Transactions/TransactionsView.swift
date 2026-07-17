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
    @Environment(TransactionImportService.self) private var importService: TransactionImportService?

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
    @State private var isShowingImportErrorDetail = false

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
            VStack(spacing: 0) {
                if let error = importService?.presentedError {
                    HStack(spacing: 12) {
                        Button {
                            isShowingImportErrorDetail = true
                        } label: {
                            PlaidErrorText(error: error)
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("transactions.importError")
                        }
                        .buttonStyle(.plain)

                        if importService?.isImporting == true {
                            ProgressView()
                                .accessibilityIdentifier("transactions.importErrorRetrying")
                        } else {
                            Button("Retry") {
                                Task { await triggerRefresh() }
                            }
                            .font(.footnote)
                            .accessibilityIdentifier("transactions.importErrorRetry")
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
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
                        .refreshable {
                            await triggerRefresh()
                        }
                    }
                }
                .navigationTitle("Transactions")
            .toolbar {
                #if DEBUG
                // reservoir-tq7: debug-only hook so XCUITest can drive the exact same
                // `triggerRefresh()` call `.refreshable` makes, without relying on a
                // synthetic pull gesture that doesn't reliably reach the underlying
                // `UIRefreshControl` in this simulator environment. Only renders when
                // `UITEST_ENABLE_REFRESH_HOOK=1` is set — never true outside XCUITest
                // launches. See `UITestScenario.isRefreshHookEnabled`.
                if UITestScenario.isRefreshHookEnabled {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Debug Refresh") {
                            Task { await triggerRefresh() }
                        }
                        .accessibilityIdentifier("transactions.debugRefreshTrigger")
                    }
                }
                #endif
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
        .sheet(isPresented: $isShowingImportErrorDetail) {
            NavigationStack {
                ScrollView {
                    Text(importService?.presentedErrorDetail ?? "No further detail available.")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("transactions.importErrorDetail")
                }
                .navigationTitle("Technical details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingImportErrorDetail = false }
                    }
                }
            }
        }
    }

    private func delete(_ transaction: SpendTransaction) {
        actionError = PersistenceSaveHelper.deleteWithRollback(
            transaction,
            modelContext: modelContext,
            logger: logger
        )
    }

    /// The one place `importService.runImport()` is invoked from this screen — both
    /// `.refreshable` and the reservoir-tq7 debug refresh hook (see the `#if DEBUG`
    /// toolbar item above) call this, so the hook genuinely exercises `.refreshable`'s
    /// code path rather than a separate proxy for it.
    private func triggerRefresh() async {
        await importService?.runImport()
    }
}

// `TransactionListRow` moved to `Reservoir/Shared/TransactionRowView.swift` (code review
// on feat/transactions) so `TodayView`/`TransactionsView` share one row implementation
// instead of two near-identical copies (STANDARDS.md §3).
