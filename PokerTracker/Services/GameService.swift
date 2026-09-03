import Foundation
import FirebaseFirestore

enum GameServiceError: LocalizedError {
    case gameNotFound
    case gameAlreadyEnded
    case codeGenerationFailed

    var errorDescription: String? {
        switch self {
        case .gameNotFound:
            return "No game found with that code. Double-check and try again."
        case .gameAlreadyEnded:
            return "This game has already ended."
        case .codeGenerationFailed:
            return "Couldn't generate a unique game code. Please try again."
        }
    }
}

final class GameService {
    static let shared = GameService()
    private let db = Firestore.firestore()
    private init() {}

    private func gameRef(_ code: String) -> DocumentReference {
        db.collection("games").document(code)
    }

    private func playersRef(_ code: String) -> CollectionReference {
        gameRef(code).collection("players")
    }

    private func editRequestsRef(_ code: String) -> CollectionReference {
        gameRef(code).collection("editRequests")
    }

    func createGame(name: String, hostUid: String, hostName: String, defaultBuyIn: Double) async throws -> PokerGame {
        for _ in 0..<8 {
            let code = GameCodeGenerator.generate()
            let ref = gameRef(code)
            let snapshot = try await ref.getDocument()
            if snapshot.exists { continue }

            let game = PokerGame(
                code: code,
                name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Poker Night" : name,
                hostId: hostUid,
                defaultBuyIn: defaultBuyIn
            )
            try await ref.setData(game.dictionary)

            let player = GamePlayer(uid: hostUid, name: hostName, buyIns: [BuyIn(amount: defaultBuyIn)])
            try await playersRef(code).document(hostUid).setData(player.dictionary)

            return game
        }
        throw GameServiceError.codeGenerationFailed
    }

    func joinGame(code: String, uid: String, name: String) async throws -> PokerGame {
        let upperCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let snapshot = try await gameRef(upperCode).getDocument()
        guard snapshot.exists, let data = snapshot.data(), let game = PokerGame(code: upperCode, data: data) else {
            throw GameServiceError.gameNotFound
        }
        guard game.status == .active else {
            throw GameServiceError.gameAlreadyEnded
        }

        let playerRef = playersRef(upperCode).document(uid)
        let existing = try await playerRef.getDocument()
        if !existing.exists {
            let player = GamePlayer(uid: uid, name: name, buyIns: [BuyIn(amount: game.defaultBuyIn)])
            try await playerRef.setData(player.dictionary)
        }
        return game
    }

    func fetchGameWithPlayers(code: String) async throws -> (PokerGame, [GamePlayer]) {
        let upperCode = code.uppercased()
        let snapshot = try await gameRef(upperCode).getDocument()
        guard snapshot.exists, let data = snapshot.data(), let game = PokerGame(code: upperCode, data: data) else {
            throw GameServiceError.gameNotFound
        }
        let playersSnapshot = try await playersRef(upperCode).getDocuments()
        let players = playersSnapshot.documents.compactMap { GamePlayer(uid: $0.documentID, data: $0.data()) }
        return (game, players)
    }

    func listenToGame(code: String, onChange: @escaping (PokerGame?) -> Void) -> ListenerRegistration {
        gameRef(code).addSnapshotListener { snapshot, _ in
            guard let snapshot, snapshot.exists, let data = snapshot.data() else {
                onChange(nil)
                return
            }
            onChange(PokerGame(code: code, data: data))
        }
    }

    func listenToPlayers(code: String, onChange: @escaping ([GamePlayer]) -> Void) -> ListenerRegistration {
        playersRef(code).addSnapshotListener { snapshot, _ in
            guard let documents = snapshot?.documents else {
                onChange([])
                return
            }
            let players = documents
                .compactMap { GamePlayer(uid: $0.documentID, data: $0.data()) }
                .sorted { $0.joinedAt < $1.joinedAt }
            onChange(players)
        }
    }

    func addBuyIn(code: String, playerUid: String, amount: Double) async throws {
        let buyIn = BuyIn(amount: amount)
        try await playersRef(code).document(playerUid).updateData([
            "buyIns": FieldValue.arrayUnion([buyIn.dictionary])
        ])
    }

    func setCashOut(code: String, playerUid: String, amount: Double) async throws {
        try await playersRef(code).document(playerUid).updateData([
            "cashOut": amount
        ])
    }

    func endGame(code: String) async throws {
        try await gameRef(code).updateData([
            "status": PokerGame.Status.ended.rawValue,
            "endedAt": Timestamp(date: Date())
        ])
    }

    // MARK: - Edit requests

    /// Requests a correction to an already-recorded buy-in or cash-out. Doesn't change
    /// anything by itself — another player has to accept it via `respondToEditRequest`.
    func requestEdit(
        code: String,
        playerUid: String,
        playerName: String,
        field: EditRequest.Field,
        buyInId: String?,
        oldAmount: Double,
        newAmount: Double,
        requestedByUid: String,
        requestedByName: String
    ) async throws {
        let request = EditRequest(
            playerUid: playerUid,
            playerName: playerName,
            field: field,
            buyInId: buyInId,
            oldAmount: oldAmount,
            newAmount: newAmount,
            requestedBy: requestedByUid,
            requestedByName: requestedByName
        )
        try await editRequestsRef(code).document(request.id).setData(request.dictionary)
    }

    func listenToEditRequests(code: String, onChange: @escaping ([EditRequest]) -> Void) -> ListenerRegistration {
        editRequestsRef(code)
            .whereField("status", isEqualTo: EditRequest.Status.pending.rawValue)
            .addSnapshotListener { snapshot, _ in
                guard let documents = snapshot?.documents else {
                    onChange([])
                    return
                }
                let requests = documents
                    .compactMap { EditRequest(id: $0.documentID, data: $0.data()) }
                    .sorted { $0.createdAt < $1.createdAt }
                onChange(requests)
            }
    }

    /// Accepting applies the correction to the player's record and resolves the request
    /// in the same transaction; rejecting just resolves it.
    func respondToEditRequest(code: String, request: EditRequest, accept: Bool, responderUid: String) async throws {
        let requestRef = editRequestsRef(code).document(request.id)

        guard accept else {
            try await requestRef.updateData([
                "status": EditRequest.Status.rejected.rawValue,
                "resolvedAt": Timestamp(date: Date()),
                "resolvedBy": responderUid
            ])
            return
        }

        let playerRef = playersRef(code).document(request.playerUid)
        _ = try await db.runTransaction { transaction, errorPointer in
            let playerSnapshot: DocumentSnapshot
            do {
                playerSnapshot = try transaction.getDocument(playerRef)
            } catch let error as NSError {
                errorPointer?.pointee = error
                return nil
            }
            guard var playerData = playerSnapshot.data() else { return nil }

            switch request.field {
            case .cashOut:
                playerData["cashOut"] = request.newAmount
            case .buyIn:
                var buyInsData = playerData["buyIns"] as? [[String: Any]] ?? []
                if let index = buyInsData.firstIndex(where: { $0["id"] as? String == request.buyInId }) {
                    buyInsData[index]["amount"] = request.newAmount
                    playerData["buyIns"] = buyInsData
                }
            }

            transaction.setData(playerData, forDocument: playerRef)
            transaction.updateData([
                "status": EditRequest.Status.approved.rawValue,
                "resolvedAt": Timestamp(date: Date()),
                "resolvedBy": responderUid
            ], forDocument: requestRef)
            return nil
        }
    }
}
