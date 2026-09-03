import Foundation

/// On-device record of finished games (for the History tab) and games currently
/// in progress (so the app can offer to "rejoin" after being backgrounded/killed).
final class LocalHistoryStore {
    static let shared = LocalHistoryStore()
    private let entriesKey = "poker.history.entries"
    private let activeCodesKey = "poker.history.activeCodes"

    private init() {}

    func loadEntries() -> [HistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: entriesKey) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    func save(_ entry: HistoryEntry) {
        var entries = loadEntries().filter { $0.code != entry.code }
        entries.insert(entry, at: 0)
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: entriesKey)
        }
    }

    func recordJoinedGame(code: String) {
        var codes = activeCodes()
        guard !codes.contains(code) else { return }
        codes.append(code)
        UserDefaults.standard.set(codes, forKey: activeCodesKey)
    }

    func activeCodes() -> [String] {
        UserDefaults.standard.stringArray(forKey: activeCodesKey) ?? []
    }

    func removeActiveCode(_ code: String) {
        let codes = activeCodes().filter { $0 != code }
        UserDefaults.standard.set(codes, forKey: activeCodesKey)
    }
}
