import SwiftUI

struct CashOutSheet: View {
    let player: GamePlayer
    var onSubmit: (Double) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText: String = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Cash out \(player.name)") {
                    TextField("Final chip count", text: $amountText)
                        .keyboardType(.decimalPad)
                    Text("Enter the total value of chips \(player.name) is cashing out with, not the profit or loss.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Cash Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        guard let amount = Double(amountText), amount >= 0 else { return }
                        isSubmitting = true
                        Task {
                            await onSubmit(amount)
                            dismiss()
                        }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Confirm")
                        }
                    }
                    .disabled(isSubmitting || Double(amountText) == nil)
                }
            }
        }
    }
}
