import Foundation

struct HistoryPlayerResult: Codable, Equatable, Hashable, Identifiable {
    var id: String { uid }
    let uid: String
    let name: String
    let totalBuyIn: Double
    let cashOut: Double?
    let net: Double?
}

struct HistoryEntry: Codable, Equatable, Hashable, Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let date: Date
    let yourNet: Double?
    let players: [HistoryPlayerResult]
}
