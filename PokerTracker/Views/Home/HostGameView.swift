import SwiftUI

struct HostGameView: View {
    let playerName: String
    var onCreated: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var gameName = ""
    @State private var defaultBuyIn = "20"
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Game details") {
                    TextField("Game name (optional)", text: $gameName)
                    HStack {
                        Text("Default buy-in")
                        Spacer()
                        TextField("20", text: $defaultBuyIn)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Host New Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await createGame() }
                    } label: {
                        if isCreating {
                            ProgressView()
                        } else {
                            Text("Create")
                        }
                    }
                    .disabled(isCreating)
                }
            }
        }
    }

    private func createGame() async {
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }

        guard let uid = AuthService.shared.currentUID else {
            errorMessage = "Not signed in yet. Try again."
            return
        }
        let amount = Double(defaultBuyIn) ?? 20

        do {
            let game = try await GameService.shared.createGame(
                name: gameName,
                hostUid: uid,
                hostName: playerName,
                defaultBuyIn: amount
            )
            LocalHistoryStore.shared.recordJoinedGame(code: game.code)
            onCreated(game.code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
