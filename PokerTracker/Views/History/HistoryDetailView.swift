import SwiftUI

struct HistoryDetailView: View {
    let entry: HistoryEntry

    var body: some View {
        List {
            Section("Results") {
                ForEach(entry.players.sorted { ($0.net ?? 0) > ($1.net ?? 0) }) { player in
                    HStack {
                        Text(player.name)
                        Spacer()
                        Text((player.net ?? 0).currencyString(showSign: true))
                            .foregroundStyle((player.net ?? 0) >= 0 ? .green : .red)
                    }
                }
            }
            Section {
                HStack {
                    Text("Game code")
                    Spacer()
                    Text(entry.code).font(.system(.body, design: .monospaced))
                }
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
