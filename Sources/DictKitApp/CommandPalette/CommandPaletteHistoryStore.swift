import Foundation

struct CommandPaletteHistory: Codable, Equatable {
    var recentWordIDs: [UUID]
    var recentCommandIDs: [String]

    static let empty = CommandPaletteHistory(recentWordIDs: [], recentCommandIDs: [])
}

final class CommandPaletteHistoryStore {
    private static let key = "commandPalette.history"
    private static let maxEntries = 5

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> CommandPaletteHistory {
        guard let data = defaults.data(forKey: Self.key),
              let history = try? decoder.decode(CommandPaletteHistory.self, from: data) else {
            return .empty
        }
        return history
    }

    func recordWord(_ id: UUID) {
        var history = load()
        history.recentWordIDs.removeAll { $0 == id }
        history.recentWordIDs.insert(id, at: 0)
        history.recentWordIDs = Array(history.recentWordIDs.prefix(Self.maxEntries))
        save(history)
    }

    func recordCommand(_ id: String) {
        var history = load()
        history.recentCommandIDs.removeAll { $0 == id }
        history.recentCommandIDs.insert(id, at: 0)
        history.recentCommandIDs = Array(history.recentCommandIDs.prefix(Self.maxEntries))
        save(history)
    }

    private func save(_ history: CommandPaletteHistory) {
        guard let data = try? encoder.encode(history) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
