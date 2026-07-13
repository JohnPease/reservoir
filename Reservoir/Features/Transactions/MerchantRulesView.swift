import SwiftUI
import SwiftData
import OSLog

/// Merchant rule list (adq.3), reachable from the Transactions tab (per the spec's locked
/// 4-tab IA — this is not its own top-level tab). Pushed onto `TransactionsView`'s own
/// `NavigationStack`, so this view does not wrap its own.
struct MerchantRulesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MerchantRule.merchantName) private var rules: [MerchantRule]

    @State private var isShowingCreateRule = false
    @State private var rulePendingEdit: MerchantRule?
    @State private var rulePendingDelete: MerchantRule?
    @State private var actionError: String?

    private let logger = Logger(subsystem: "com.reservoir.app", category: "MerchantRulesView")

    var body: some View {
        Group {
            if rules.isEmpty {
                ContentUnavailableView(
                    "No merchant rules yet",
                    systemImage: "tag",
                    description: Text("Add a rule to automatically tag transactions by merchant.")
                )
                .accessibilityIdentifier("merchantRules.emptyState")
            } else {
                List {
                    ForEach(rules, id: \.persistentModelID) { rule in
                        Button {
                            rulePendingEdit = rule
                        } label: {
                            HStack {
                                Text(rule.merchantName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(rule.type == .fixed ? "Fixed" : "Variable")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("merchantRules.row")
                        .swipeActions {
                            Button(role: .destructive) {
                                rulePendingDelete = rule
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .accessibilityIdentifier("merchantRules.list")
            }
        }
        .navigationTitle("Merchant Rules")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingCreateRule = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("merchantRules.addRule")
            }
        }
        .sheet(isPresented: $isShowingCreateRule) {
            MerchantRuleEntryView(mode: .create, accessibilityIdentifier: "merchantRules.createSheet")
        }
        .editSheet(pendingItem: $rulePendingEdit) { rule in
            MerchantRuleEntryView(mode: .edit(rule), accessibilityIdentifier: "merchantRules.editSheet")
        }
        .deleteConfirmation(
            pendingItem: $rulePendingDelete,
            title: { _ in "Delete this merchant rule? Existing transactions keep their current tag." },
            onDelete: delete
        )
        .saveErrorAlert($actionError)
    }

    /// Deleting a rule does not touch existing transactions' tags (asymmetric on purpose
    /// vs. create/edit's retag pass — see `MerchantRuleRetagCalculator`'s doc comment).
    private func delete(_ rule: MerchantRule) {
        actionError = PersistenceSaveHelper.deleteWithRollback(
            rule,
            modelContext: modelContext,
            logger: logger
        )
    }
}
