import Foundation

struct SettlementTransaction: Identifiable, Equatable {
    let id = UUID()
    let fromName: String
    let toName: String
    let amount: Double
}
