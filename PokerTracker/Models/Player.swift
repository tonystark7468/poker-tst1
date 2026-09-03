import Foundation
import FirebaseFirestore

struct BuyIn: Identifiable, Equatable {
    let id: String
    let amount: Double
    let timestamp: Date

    init(id: String = UUID().uuidString, amount: Double, timestamp: Date = Date()) {
        self.id = id
        self.amount = amount
        self.timestamp = timestamp
    }

    init?(data: [String: Any]) {
        guard
            let id = data["id"] as? String,
            let amount = data["amount"] as? Double,
            let ts = data["timestamp"] as? Timestamp
        else { return nil }
        self.id = id
        self.amount = amount
        self.timestamp = ts.dateValue()
    }

    var dictionary: [String: Any] {
        ["id": id, "amount": amount, "timestamp": Timestamp(date: timestamp)]
    }
}

struct GamePlayer: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    var name: String
    var buyIns: [BuyIn]
    var cashOut: Double?
    let joinedAt: Date

    var totalBuyIn: Double { buyIns.reduce(0) { $0 + $1.amount } }
    var hasCashedOut: Bool { cashOut != nil }
    var net: Double? {
        guard let cashOut else { return nil }
        return cashOut - totalBuyIn
    }

    init(uid: String, name: String, buyIns: [BuyIn] = [], cashOut: Double? = nil, joinedAt: Date = Date()) {
        self.uid = uid
        self.name = name
        self.buyIns = buyIns
        self.cashOut = cashOut
        self.joinedAt = joinedAt
    }

    init?(uid: String, data: [String: Any]) {
        guard
            let name = data["name"] as? String,
            let joinedAtTS = data["joinedAt"] as? Timestamp
        else { return nil }

        self.uid = uid
        self.name = name
        self.joinedAt = joinedAtTS.dateValue()
        let buyInsData = data["buyIns"] as? [[String: Any]] ?? []
        self.buyIns = buyInsData.compactMap { BuyIn(data: $0) }
        self.cashOut = data["cashOut"] as? Double
    }

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "uid": uid,
            "name": name,
            "buyIns": buyIns.map { $0.dictionary },
            "joinedAt": Timestamp(date: joinedAt)
        ]
        if let cashOut {
            dict["cashOut"] = cashOut
        }
        return dict
    }
}
