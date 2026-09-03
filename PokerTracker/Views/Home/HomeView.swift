import SwiftUI

enum HomeRoute: Hashable {
    case gameRoom(code: String)
}

struct HomeView: View {
    @AppStorage("playerName") private var playerName: String = ""
    @State private var path: [HomeRoute] = []
    @State private var showHost = false
    @State private var showJoin = false
    @State private var resumeCode: String?

    private var trimmedName: String { playerName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                VStack(spacing: 4) {
                    Text("🃏 Poker Tracker")
                        .font(.largeTitle.bold())
                    Text("Track buy-ins, cash-outs, and settle up.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. Alex", text: $playerName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                }
                .padding(.horizontal)

                if let resumeCode {
                    Button {
                        path.append(.gameRoom(code: resumeCode))
                    } label: {
                        Label("Rejoin game \(resumeCode)", systemImage: "arrow.uturn.backward.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        showHost = true
                    } label: {
                        Text("Host New Game")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)

                    Button {
                        showJoin = true
                    } label: {
                        Text("Join Game")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .buttonStyle(.bordered)
                    .disabled(trimmedName.isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .gameRoom(let code):
                    GameRoomView(code: code, playerName: trimmedName)
                }
            }
            .sheet(isPresented: $showHost) {
                HostGameView(playerName: trimmedName) { code in
                    showHost = false
                    path.append(.gameRoom(code: code))
                }
            }
            .sheet(isPresented: $showJoin) {
                JoinGameView(playerName: trimmedName) { code in
                    showJoin = false
                    path.append(.gameRoom(code: code))
                }
            }
            .task {
                await checkResume()
            }
        }
    }

    private func checkResume() async {
        guard let code = LocalHistoryStore.shared.activeCodes().first else { return }
        do {
            let (game, _) = try await GameService.shared.fetchGameWithPlayers(code: code)
            if game.status == .active {
                resumeCode = code
            } else {
                LocalHistoryStore.shared.removeActiveCode(code)
            }
        } catch {
            LocalHistoryStore.shared.removeActiveCode(code)
        }
    }
}
