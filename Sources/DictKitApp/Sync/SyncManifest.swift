import Foundation

/// The top-level manifest exchanged via WebDAV for the current sync generation.
struct SyncManifest: Codable, Equatable {
    static let currentFormat = "ankimate-sync-v2"
    static let currentVersion = 2

    let format: String
    let version: Int
    let deviceId: String
    let exportedAt: TimeInterval
    var collections: [SyncCollectionRecord]
    var words: [SyncWordRecord]

    init(deviceId: String, collections: [SyncCollectionRecord], words: [SyncWordRecord]) {
        self.format = Self.currentFormat
        self.version = Self.currentVersion
        self.deviceId = deviceId
        self.exportedAt = Date().timeIntervalSince1970
        self.collections = collections
        self.words = words
    }
}

struct SyncCollectionRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var dictionaryName: String
    var deckDescription: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var deletedAt: TimeInterval?

    var isDeleted: Bool {
        deletedAt != nil
    }
}

struct SyncWordPayloadRecord: Codable, Equatable {
    var lookupStateBase64: String?
    var lookupRefreshedAt: TimeInterval?
    var payloadUpdatedAt: TimeInterval
    var audioRef: String?
    var aiArtifactsJSON: String?
}

struct SyncWordRecord: Codable, Identifiable, Equatable {
    let id: String
    var collectionId: String
    var normalizedWord: String
    var displayWord: String
    var sourceForm: String?
    var inflectionKind: String?
    var expectedPartOfSpeech: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var deletedAt: TimeInterval?
    var payload: SyncWordPayloadRecord

    var isDeleted: Bool {
        deletedAt != nil
    }
}

struct LegacySyncManifest: Codable {
    let version: Int
    let deviceId: String
    let lastSyncedAt: TimeInterval
    var collections: [LegacySyncCollectionRecord]
    var words: [LegacySyncWordRecord]
}

struct LegacySyncCollectionRecord: Codable {
    let id: String
    var name: String
    var dictionaryName: String
    var deckDescription: String
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var isDeleted: Bool
}

struct LegacySyncWordRecord: Codable {
    let id: String
    var collectionId: String
    var normalizedWord: String
    var displayWord: String
    var sourceForm: String?
    var inflectionKind: String?
    var expectedPartOfSpeech: String?
    var lookupStateBase64: String?
    var audioRef: String?
    var createdAt: TimeInterval
    var updatedAt: TimeInterval
    var lastRefreshedAt: TimeInterval?
    var isDeleted: Bool
}

enum PulledManifest {
    case current(SyncManifest)
    case legacy(LegacySyncManifest)
}
