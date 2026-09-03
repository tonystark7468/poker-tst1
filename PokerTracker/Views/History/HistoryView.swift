import SwiftUI

struct HistoryView: View {
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No games yet",
                        systemImage: "clock",
                        description: Text("Games you finish will show up here.")
                    )
                } else {
                    List(entries) { entry in
                        NavigationLink(value: entry) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let net = entry.yourNet {
                                    Text(net.currencyString(showSign: true))
                                        .foregroundStyle(net >= 0 ? .green : .red)
                                        .font(.headline.monospacedDigit())
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationDestination(for: HistoryEntry.self) { entry in
                HistoryDetailView(entry: entry)
            }
            .onAppear {
                entries = LocalHistoryStore.shared.loadEntries()
            }
        }
    }
}
