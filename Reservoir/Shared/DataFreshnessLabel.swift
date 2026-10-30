import SwiftUI

/// One quiet caption saying when imported data was last synced and how recent its newest
/// charge is (reservoir-3oe). Renders nothing when there is nothing to say.
struct DataFreshnessLabel: View {
    let lastSync: Date?
    let transactions: [SpendTransaction]
    let now: Date
    var identifier = "dataFreshness"

    var body: some View {
        if let text = DataFreshnessCalculator.text(
            lastSync: lastSync,
            newestImportedDate: DataFreshnessCalculator.newestImportedDate(transactions),
            now: now
        ) {
            Text(text)
                .font(.caption)
                .foregroundStyle(Color("ReservoirTextMuted"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(identifier)
        }
    }
}
