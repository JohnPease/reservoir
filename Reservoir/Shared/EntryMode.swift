/// Shared create/edit mode for entry forms (`GoalFormView`, `TransactionEntryView`,
/// `MerchantRuleEntryView`) — extracted because the `Mode { case create; case
/// edit(T); var isEdit }` shape was duplicated verbatim (modulo associated type) across
/// all three (STANDARDS.md §3, no copy-paste). Each view aliases this as its own `Mode`
/// (e.g. `typealias Mode = EntryMode<SavingsGoal>`) so call sites are unaffected.
enum EntryMode<T> {
    case create
    case edit(T)

    var isEdit: Bool {
        if case .edit = self { return true }
        return false
    }
}
