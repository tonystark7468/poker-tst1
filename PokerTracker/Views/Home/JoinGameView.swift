import SwiftUI

struct JoinGameView: View {
    let playerName: String
    var onJoined: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isJoining = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Game code") {
                    TextField("e.g. PK4X9", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Join Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await joinGame() }
                    } label: {
                        if isJoining {
                            ProgressView()
                        } else {
                            Text("Join")
                        }
                    }
                    .disabled(isJoining || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func joinGame() async {
        isJoining = true
        errorMessage = nil
        defer { isJoining = false }

        guard let uid = AuthService.shared.currentUID else {
            errorMessage = "Not signed in yet. Try again."
            return
        }

        do {
            let game = try await GameService.shared.joinGame(code: code, uid: uid, name: playerName)
            LocalHistoryStore.shared.recordJoinedGame(code: game.code)
            onJoined(game.code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
