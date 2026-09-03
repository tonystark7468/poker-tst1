import Foundation

/// Reduces everyone's net win/loss to the minimum number of payments needed to settle up,
/// by repeatedly matching the largest creditor with the largest debtor.
enum SettlementCalculator {
    static func calculate(players: [GamePlayer]) -> [SettlementTransaction] {
        let balances: [(name: String, amount: Double)] = players.compactMap { player in
            guard let net = player.net else { return nil }
            return (player.name, net)
        }

        var creditors = balances.filter { $0.amount > 0.005 }.sorted { $0.amount > $1.amount }
        var debtors = balances.filter { $0.amount < -0.005 }.sorted { $0.amount < $1.amount }

        var transactions: [SettlementTransaction] = []
        var i = 0
        var j = 0
        while i < debtors.count && j < creditors.count {
            let owed = -debtors[i].amount
            let due = creditors[j].amount
            let amount = min(owed, due)

            if amount > 0.005 {
                transactions.append(
                    SettlementTransaction(fromName: debtors[i].name, toName: creditors[j].name, amount: amount)
                )
            }

            debtors[i].amount += amount
            creditors[j].amount -= amount

            if abs(debtors[i].amount) < 0.005 { i += 1 }
            if abs(creditors[j].amount) < 0.005 { j += 1 }
        }

        return transactions
    }
}
