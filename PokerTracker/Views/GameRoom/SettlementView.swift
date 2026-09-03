import SwiftUI

struct SettlementView: View {
    let game: PokerGame
    let players: [GamePlayer]

    @Environment(\.dismiss) private var dismiss

    private var transactions: [SettlementTransaction] {
        SettlementCalculator.calculate(players: players)
    }

    private var totalPot: Double {
        players.reduce(0) { $0 + $1.totalBuyIn }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Results") {
                    ForEach(players.sorted { ($0.net ?? 0) > ($1.net ?? 0) }) { player in
                        HStack {
                            Text(player.name)
                            Spacer()
                            Text((player.net ?? 0).currencyString(showSign: true))
                                .foregroundStyle((player.net ?? 0) >= 0 ? .green : .red)
                                .font(.headline.monospacedDigit())
                        }
                    }
                }

                Section("Who pays who") {
                    if transactions.isEmpty {
                        Text("Everyone's settled up. 🎉")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(transactions) { tx in
                            HStack {
                                Text(tx.fromName).fontWeight(.medium)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                Text(tx.toName).fontWeight(.medium)
                                Spacer()
                                Text(tx.amount.currencyString)
                                    .fontWeight(.semibold)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Total pot")
                        Spacer()
                        Text(totalPot.currencyString)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(game.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
