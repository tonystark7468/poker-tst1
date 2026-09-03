import SwiftUI

struct RootView: View {
    @State private var isReady = false
    @State private var authError: String?

    var body: some View {
        Group {
            if isReady {
                MainTabView()
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Setting up...")
                        .foregroundStyle(.secondary)
                    if let authError {
                        Text(authError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Try Again") {
                            Task { await signIn() }
                        }
                    }
                }
            }
        }
        .task {
            await signIn()
        }
    }

    private func signIn() async {
        do {
            _ = try await AuthService.shared.ensureSignedIn()
            authError = nil
            isReady = true
        } catch {
            authError = "Couldn't connect: \(error.localizedDescription)"
        }
    }
}
