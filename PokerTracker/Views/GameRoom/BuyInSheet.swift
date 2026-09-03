import SwiftUI

struct BuyInSheet: View {
    let player: GamePlayer
    let defaultAmount: Double
    var onSubmit: (Double) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String
    @State private var isSubmitting = false

    init(player: GamePlayer, defaultAmount: Double, onSubmit: @escaping (Double) async -> Void) {
        self.player = player
        self.defaultAmount = defaultAmount
        self.onSubmit = onSubmit
        _amountText = State(initialValue: String(format: "%.0f", defaultAmount))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add buy-in for \(player.name)") {
                    TextField("Amount", text: $amountText)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle("Buy-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let amount = Double(amountText), amount > 0 else { return }
                        isSubmitting = true
                        Task {
                            await onSubmit(amount)
                            dismiss()
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(isSubmitting || Double(amountText) == nil)
                }
            }
        }
    }
}
