import Foundation
import FirebaseFirestore

struct PokerGame: Identifiable, Equatable {
    enum Status: String {
        case active
        case ended
    }

    var id: String { code }
    let code: String
    var name: String
    let hostId: String
    var status: Status
    var defaultBuyIn: Double
    let createdAt: Date
    var endedAt: Date?

    init(
        code: String,
        name: String,
        hostId: String,
        status: Status = .active,
        defaultBuyIn: Double,
        createdAt: Date = Date(),
        endedAt: Date? = nil
    ) {
        self.code = code
        self.name = name
        self.hostId = hostId
        self.status = status
        self.defaultBuyIn = defaultBuyIn
        self.createdAt = createdAt
        self.endedAt = endedAt
    }

    init?(code: String, data: [String: Any]) {
        guard
            let name = data["name"] as? String,
            let hostId = data["hostId"] as? String,
            let statusRaw = data["status"] as? String,
            let status = Status(rawValue: statusRaw),
            let defaultBuyIn = data["defaultBuyIn"] as? Double,
            let createdAtTS = data["createdAt"] as? Timestamp
        else { return nil }

        self.code = code
        self.name = name
        self.hostId = hostId
        self.status = status
        self.defaultBuyIn = defaultBuyIn
        self.createdAt = createdAtTS.dateValue()
        self.endedAt = (data["endedAt"] as? Timestamp)?.dateValue()
    }

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "code": code,
            "name": name,
            "hostId": hostId,
            "status": status.rawValue,
            "defaultBuyIn": defaultBuyIn,
            "createdAt": Timestamp(date: createdAt)
        ]
        if let endedAt {
            dict["endedAt"] = Timestamp(date: endedAt)
        }
        return dict
    }
}
