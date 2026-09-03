import SwiftUI
import UIKit
import FirebaseFirestore

struct GameRoomView: View {
    let code: String
    let playerName: String

    @State private var game: PokerGame?
    @State private var players: [GamePlayer] = []
    @State private var gameListener: ListenerRegistration?
    @State private var playersListener: ListenerRegistration?
    @State private var showBuyInSheet: GamePlayer?
    @State private var showCashOutSheet: GamePlayer?
    @State private var showEditSheet: GamePlayer?
    @State private var showShareSheet = false
    @State private var showEndGameConfirm = false
    @State private var showMissingCashOutAlert = false
    @State private var showSettlement = false
    @State private var errorMessage: String?
    @State private var editRequests: [EditRequest] = []
    @State private var editRequestsListener: ListenerRegistration?

    private var myUid: String? { AuthService.shared.currentUID }
    private var isHost: Bool { game?.hostId == myUid }
    private var playersStillIn: [GamePlayer] { players.filter { !$0.hasCashedOut } }

    var body: some View {
        Group {
            if let game {
                content(game: game)
            } else {
                ProgressView("Loading game...")
            }
        }
        .navigationTitle("Game Room")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: attachListeners)
        .onDisappear(perform: detachListeners)
        .sheet(item: $showBuyInSheet) { player in
            BuyInSheet(player: player, defaultAmount: game?.defaultBuyIn ?? 20) { amount in
                await submitBuyIn(player: player, amount: amount)
            }
        }
        .sheet(item: $showCashOutSheet) { player in
            CashOutSheet(player: player) { amount in
                await submitCashOut(player: player, amount: amount)
            }
        }
        .sheet(item: $showEditSheet) { player in
            if let myUid {
                EditRequestSheet(code: code, player: player, requesterUid: myUid, requesterName: playerName)
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: ["Join my poker game! Code: \(code)"])
        }
        .sheet(isPresented: $showSettlement) {
            if let game {
                SettlementView(game: game, players: players)
            }
        }
        .confirmationDialog("End the game for everyone?", isPresented: $showEndGameConfirm, titleVisibility: .visible) {
            Button("End Game", role: .destructive) {
                Task { await endGame() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This locks in all buy-ins and cash-outs and calculates who owes who.")
        }
        .alert("Not everyone has cashed out", isPresented: $showMissingCashOutAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Still in play: \(playersStillIn.map(\.name).joined(separator: ", "))")
        }
    }

    @ViewBuilder
    private func content(game: PokerGame) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(code)
                            .font(.system(.title, design: .monospaced, weight: .bold))
                        Spacer()
                        Button {
                            UIPasteboard.general.string = code
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    Text(game.name)
                        .font(.headline)
                    Text(game.status == .active ? "Game in progress" : "Game ended")
                        .font(.caption)
                        .foregroundStyle(game.status == .active ? .green : .secondary)
                }
                .padding(.vertical, 4)
            }

            if !editRequests.isEmpty {
                Section("Pending Requests") {
                    ForEach(editRequests) { request in
                        editRequestRow(request)
                    }
                }
            }

            Section("Players (\(players.count))") {
                ForEach(players) { player in
                    PlayerRowView(player: player, isMe: player.uid == myUid)
                        .swipeActions(edge: .trailing) {
                            if game.status == .active {
                                Button {
                                    showBuyInSheet = player
                                } label: {
                                    Label("Buy-in", systemImage: "plus.circle")
                                }
                                .tint(.green)

                                if !player.hasCashedOut {
                                    Button {
                                        showCashOutSheet = player
                                    } label: {
                                        Label("Cash out", systemImage: "checkmark.circle")
                                    }
                                    .tint(.blue)
                                }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if game.status == .active && (!player.buyIns.isEmpty || player.hasCashedOut) {
                                Button {
                                    showEditSheet = player
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }

            if isHost && game.status == .active {
                Section {
                    Button(role: .destructive) {
                        if playersStillIn.isEmpty {
                            showEndGameConfirm = true
                        } else {
                            showMissingCashOutAlert = true
                        }
                    } label: {
                        Text("End Game & Settle Up")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            if game.status == .ended {
                Section {
                    Button {
                        showSettlement = true
                    } label: {
                        Text("View Settlement")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func editRequestRow(_ request: EditRequest) -> some View {
        let fieldLabel = request.field == .buyIn ? "buy-in" : "cash-out"
        VStack(alignment: .leading, spacing: 6) {
            Text("\(request.requestedByName) wants to change \(request.playerName)'s \(fieldLabel) from \(request.oldAmount.currencyString) to \(request.newAmount.currencyString)")
                .font(.subheadline)

            if request.requestedBy == myUid {
                Text("Waiting for another player to accept…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("Accept") {
                        Task { await respond(to: request, accept: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button("Reject") {
                        Task { await respond(to: request, accept: false) }
                    }
                    .buttonStyle(.bordered)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func attachListeners() {
        gameListener = GameService.shared.listenToGame(code: code) { updatedGame in
            let previousStatus = game?.status
            game = updatedGame
            if let updatedGame, updatedGame.status == .ended, previousStatus != .ended {
                LocalHistoryStore.shared.removeActiveCode(code)
                saveHistorySnapshot(game: updatedGame)
                showSettlement = true
            }
        }
        playersListener = GameService.shared.listenToPlayers(code: code) { updatedPlayers in
            players = updatedPlayers
        }
        editRequestsListener = GameService.shared.listenToEditRequests(code: code) { updatedRequests in
            editRequests = updatedRequests
        }
    }

    private func detachListeners() {
        gameListener?.remove()
        playersListener?.remove()
        editRequestsListener?.remove()
    }

    private func respond(to request: EditRequest, accept: Bool) async {
        guard let uid = myUid else { return }
        do {
            try await GameService.shared.respondToEditRequest(code: code, request: request, accept: accept, responderUid: uid)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitBuyIn(player: GamePlayer, amount: Double) async {
        do {
            try await GameService.shared.addBuyIn(code: code, playerUid: player.uid, amount: amount)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submitCashOut(player: GamePlayer, amount: Double) async {
        do {
            try await GameService.shared.setCashOut(code: code, playerUid: player.uid, amount: amount)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func endGame() async {
        do {
            try await GameService.shared.endGame(code: code)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveHistorySnapshot(game: PokerGame) {
        let results = players.map { player in
            HistoryPlayerResult(
                uid: player.uid,
                name: player.name,
                totalBuyIn: player.totalBuyIn,
                cashOut: player.cashOut,
                net: player.net
            )
        }
        let mine = results.first { $0.uid == myUid }
        let entry = HistoryEntry(
            code: game.code,
            name: game.name,
            date: game.endedAt ?? Date(),
            yourNet: mine?.net,
            players: results
        )
        LocalHistoryStore.shared.save(entry)
    }
}
