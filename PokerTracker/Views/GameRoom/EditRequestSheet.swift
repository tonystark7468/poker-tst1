import SwiftUI

enum EditableItem: Identifiable {
    case buyIn(BuyIn)
    case cashOut(Double)

    var id: String {
        switch self {
        case .buyIn(let buyIn): return "buyIn-\(buyIn.id)"
        case .cashOut: return "cashOut"
        }
    }

    var label: String {
        switch self {
        case .buyIn: return "Buy-in"
        case .cashOut: return "Cash-out"
        }
    }

    var amount: Double {
        switch self {
        case .buyIn(let buyIn): return buyIn.amount
        case .cashOut(let amount): return amount
        }
    }

    var field: EditRequest.Field {
        switch self {
        case .buyIn: return .buyIn
        case .cashOut: return .cashOut
        }
    }

    var buyInId: String? {
        switch self {
        case .buyIn(let buyIn): return buyIn.id
        case .cashOut: return nil
        }
    }
}

struct EditRequestSheet: View {
    let code: String
    let player: GamePlayer
    let requesterUid: String
    let requesterName: String

    @Environment(\.dismiss) private var dismiss

    private var items: [EditableItem] {
        var result = player.buyIns.map(EditableItem.buyIn)
        if let cashOut = player.cashOut {
            result.append(.cashOut(cashOut))
        }
        return result
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("Nothing to edit yet", systemImage: "pencil.slash")
                } else {
                    List(items) { item in
                        NavigationLink {
                            EditAmountView(
                                code: code,
                                player: player,
                                item: item,
                                requesterUid: requesterUid,
                                requesterName: requesterName,
                                onSubmitted: { dismiss() }
                            )
                        } label: {
                            HStack {
                                Text(item.label)
                                Spacer()
                                Text(item.amount.currencyString)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Edit \(player.name)'s Entries")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct EditAmountView: View {
    let code: String
    let player: GamePlayer
    let item: EditableItem
    let requesterUid: String
    let requesterName: String
    var onSubmitted: () -> Void

    @State private var amountText: String
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        code: String,
        player: GamePlayer,
        item: EditableItem,
        requesterUid: String,
        requesterName: String,
        onSubmitted: @escaping () -> Void
    ) {
        self.code = code
        self.player = player
        self.item = item
        self.requesterUid = requesterUid
        self.requesterName = requesterName
        self.onSubmitted = onSubmitted
        _amountText = State(initialValue: String(format: "%.0f", item.amount))
    }

    var body: some View {
        Form {
            Section("Current \(item.label.lowercased())") {
                Text(item.amount.currencyString)
                    .foregroundStyle(.secondary)
            }
            Section("New amount") {
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
            }
            Section {
                Text("This won't change anything until another player at the table accepts the request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("New Amount")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await submit() }
                } label: {
                    if isSubmitting {
                        ProgressView()
                    } else {
                        Text("Send Request")
                    }
                }
                .disabled(isSubmitting || Double(amountText) == nil)
            }
        }
    }

    private func submit() async {
        guard let newAmount = Double(amountText), newAmount >= 0 else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await GameService.shared.requestEdit(
                code: code,
                playerUid: player.uid,
                playerName: player.name,
                field: item.field,
                buyInId: item.buyInId,
                oldAmount: item.amount,
                newAmount: newAmount,
                requestedByUid: requesterUid,
                requestedByName: requesterName
            )
            onSubmitted()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
