import SwiftUI

/// Settings > Sync log (reservoir-bz5): the on-device record of each `/transactions/sync`
/// run, newest first, with a button to copy it as text.
struct SyncLogView: View {
    private let store: SyncLogStoring
    @State private var entries: [SyncLogEntry]
    @State private var confirmingClear = false

    init(store: SyncLogStoring = SyncLogStore()) {
        self.store = store
        self._entries = State(initialValue: store.entries())
    }

    var body: some View {
        List {
            if entries.isEmpty {
                Text("No syncs recorded yet. Pull down on Transactions to run one.")
                    .foregroundStyle(Color("ReservoirTextSecondary"))
                    .accessibilityIdentifier("syncLog.empty")
            }
            ForEach(entries.reversed()) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(Color("ReservoirTextMuted"))
                    Text(entry.message)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color("ReservoirTextPrimary"))
                }
                .listRowBackground(Color("ReservoirSurface"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color("ReservoirBackground"))
        .navigationTitle("Sync log")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: SyncLogFormatter.text(entries)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share sync log")
                .accessibilityIdentifier("syncLog.share")
                Button(role: .destructive) { confirmingClear = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Clear sync log")
                .accessibilityIdentifier("syncLog.clear")
                .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog("Clear the sync log?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                store.clear()
                entries = []
            }
        }
        .refreshable { entries = store.entries() }
        .onAppear { entries = store.entries() }
    }
}
