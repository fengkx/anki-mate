import Foundation

/// The top-level manifest exchanged via WebDAV.
struct SyncManifest: Codable {
    static let currentVersion = 1

    let version: Int
    let deviceId: String
    let lastSyncedAt: TimeInterval
    var collections: [SyncCollectionRecord]
    var words: [SyncWordRecord]

    init(deviceId: String, collections: [SyncCollectionRecord], words: [SyncWordRecord]) {
        self.version = Self.currentVersion
        self.deviceId = deviceId
        self.lastSyncedAt = Date().timeIntervalSince1970
        self.collections = collections
        self.words = words
    }
}

/// A collection record as represented in the sync manifest.
struct SyncCollectionRecord: Codable, Identifiable {
    let id: String
    var name: String
    var dictionaryName: String
    var ankiDeckName: String
    var deckDescription: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var isDeleted: Bool
}

/// A word record as represented in the sync manifest.
struct SyncWordRecord: Codable, Identifiable {
    let id: String
    var collectionId: String
    var normalizedWord: String
    var displayWord: String
    var sourceForm: String?
    var inflectionKind: String?
    var expectedPartOfSpeech: String?
    /// Base64-encoded JSON blob of the lookup state.
    var lookupStateBase64: String?
    /// SHA-256 hex hash of audio data. Nil means no audio.
    var audioRef: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastRefreshedAt: TimeInterval?
    var isDeleted: Bool
}
