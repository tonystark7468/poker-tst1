import Foundation
import FirebaseFirestore

/// A request to change an already-recorded buy-in or cash-out amount.
/// Adding a brand-new buy-in or a first cash-out doesn't need one of these —
/// only correcting a value that's already on the books does, and it takes
/// another player at the table (not the requester) to accept it before the
/// change is applied.
struct EditRequest: Identifiable, Equatable {
    enum Field: String {
        case buyIn
        case cashOut
    }

    enum Status: String {
        case pending
        case approved
        case rejected
    }

    let id: String
    let playerUid: String
    let playerName: String
    let field: Field
    let buyInId: String?
    let oldAmount: Double
    let newAmount: Double
    let requestedBy: String
    let requestedByName: String
    var status: Status
    let createdAt: Date
    var resolvedAt: Date?
    var resolvedBy: String?

    init(
        id: String = UUID().uuidString,
        playerUid: String,
        playerName: String,
        field: Field,
        buyInId: String?,
        oldAmount: Double,
        newAmount: Double,
        requestedBy: String,
        requestedByName: String,
        status: Status = .pending,
        createdAt: Date = Date(),
        resolvedAt: Date? = nil,
        resolvedBy: String? = nil
    ) {
        self.id = id
        self.playerUid = playerUid
        self.playerName = playerName
        self.field = field
        self.buyInId = buyInId
        self.oldAmount = oldAmount
        self.newAmount = newAmount
        self.requestedBy = requestedBy
        self.requestedByName = requestedByName
        self.status = status
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
    }

    init?(id: String, data: [String: Any]) {
        guard
            let playerUid = data["playerUid"] as? String,
            let playerName = data["playerName"] as? String,
            let fieldRaw = data["field"] as? String,
            let field = Field(rawValue: fieldRaw),
            let oldAmount = data["oldAmount"] as? Double,
            let newAmount = data["newAmount"] as? Double,
            let requestedBy = data["requestedBy"] as? String,
            let requestedByName = data["requestedByName"] as? String,
            let statusRaw = data["status"] as? String,
            let status = Status(rawValue: statusRaw),
            let createdAtTS = data["createdAt"] as? Timestamp
        else { return nil }

        self.id = id
        self.playerUid = playerUid
        self.playerName = playerName
        self.field = field
        self.buyInId = data["buyInId"] as? String
        self.oldAmount = oldAmount
        self.newAmount = newAmount
        self.requestedBy = requestedBy
        self.requestedByName = requestedByName
        self.status = status
        self.createdAt = createdAtTS.dateValue()
        self.resolvedAt = (data["resolvedAt"] as? Timestamp)?.dateValue()
        self.resolvedBy = data["resolvedBy"] as? String
    }

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            "playerUid": playerUid,
            "playerName": playerName,
            "field": field.rawValue,
            "oldAmount": oldAmount,
            "newAmount": newAmount,
            "requestedBy": requestedBy,
            "requestedByName": requestedByName,
            "status": status.rawValue,
            "createdAt": Timestamp(date: createdAt)
        ]
        if let buyInId {
            dict["buyInId"] = buyInId
        }
        if let resolvedAt {
            dict["resolvedAt"] = Timestamp(date: resolvedAt)
        }
        if let resolvedBy {
            dict["resolvedBy"] = resolvedBy
        }
        return dict
    }
}
