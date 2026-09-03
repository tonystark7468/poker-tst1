import SwiftUI

struct PlayerRowView: View {
    let player: GamePlayer
    let isMe: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(player.name)
                        .font(.headline)
                    if isMe {
                        Text("you")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
                Text("Buy-in: \(player.totalBuyIn.currencyString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let net = player.net {
                Text(net.currencyString(showSign: true))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(net >= 0 ? .green : .red)
            } else {
                Text("In play")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}
