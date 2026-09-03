import FirebaseAuth

final class AuthService {
    static let shared = AuthService()
    private init() {}

    var currentUID: String? { Auth.auth().currentUser?.uid }

    @discardableResult
    func ensureSignedIn() async throws -> String {
        if let uid = Auth.auth().currentUser?.uid {
            return uid
        }
        let result = try await Auth.auth().signInAnonymously()
        return result.user.uid
    }
}
