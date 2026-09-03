import Foundation

enum GameCodeGenerator {
    // Excludes visually ambiguous characters: 0/O, 1/I/L.
    private static let allowedCharacters = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func generate(length: Int = 5) -> String {
        String((0..<length).compactMap { _ in allowedCharacters.randomElement() })
    }
}
