import DictKit
import Foundation
import XCTest
@testable import DictKitApp

@MainActor
final class SyncEngineTests: XCTestCase {
    func testSyncUpgradesLegacyRemoteManifestAndImportsData() async throws {
        let store = try makeStore()
        let status = SyncStatus()
        let legacyAudio = Data([0x10, 0x20, 0x30])
        let legacyAudioHash = SyncAudioStore.hash(legacyAudio)
        let legacyManifest = LegacySyncManifest(
            version: 1,
            deviceId: "legacy-device",
            lastSyncedAt: 123,
            collections: [
                LegacySyncCollectionRecord(
                    id: UUID().uuidString,
                    name: "Reading",
                    dictionaryName: "ODE",
                    ankiDeckName: "Reading",
                    deckDescription: "Remote deck",
                    createdAt: 10,
                    updatedAt: 20,
                    isDeleted: false
                )
            ],
            words: [
                LegacySyncWordRecord(
                    id: UUID().uuidString,
                    collectionId: "",
                    normalizedWord: "apple",
                    displayWord: "Apple",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    lookupStateBase64: try JSONEncoder().encode(PersistedLookupState.pending).base64EncodedString(),
                    audioRef: legacyAudioHash,
                    createdAt: 10,
                    updatedAt: 30,
                    lastRefreshedAt: 25,
                    isDeleted: false
                )
            ]
        )
        var fixedLegacyManifest = legacyManifest
        fixedLegacyManifest.words[0].collectionId = fixedLegacyManifest.collections[0].id

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let client = FakeWebDAVClient(
            files: [
                "anki-mate/manifest.json": try encoder.encode(fixedLegacyManifest),
                SyncAudioStore.remotePath(for: legacyAudioHash): legacyAudio
            ]
        )

        var onStoreChangedCount = 0
        let engine = SyncEngine(
            store: store,
            status: status,
            environment: .init(
                loadCredentials: { testWebDAVCredentials },
                makeClient: { _ in client }
            ),
            onStoreChanged: {
                onStoreChangedCount += 1
            }
        )

        await engine.sync()

        let collections = try store.loadCollections()
        let words = try store.loadAllWords()
        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.only?.name, "Reading")
        XCTAssertEqual(words.only?.displayWord, "Apple")
        XCTAssertEqual(words.only?.audioData, legacyAudio)
        XCTAssertEqual(status.state, .idle)
        XCTAssertFalse(status.hasPendingChanges)
        XCTAssertNil(status.lastError)
        XCTAssertEqual(onStoreChangedCount, 1)

        let upgradedData = await client.file(at: "anki-mate/manifest.json")
        let unwrappedUpgradedData = try XCTUnwrap(upgradedData)
        let upgradedManifest = try JSONDecoder().decode(SyncManifest.self, from: unwrappedUpgradedData)
        XCTAssertEqual(upgradedManifest.format, SyncManifest.currentFormat)
        XCTAssertEqual(upgradedManifest.words.only?.payload.audioRef, legacyAudioHash)

        let backupPaths = await client.paths(withPrefix: "anki-mate/backups/manifest-v1-")
        XCTAssertEqual(backupPaths.count, 1)
        XCTAssertNotNil(try store.syncMetadata(forKey: "last_sync_timestamp"))
        let lockFile = await client.file(at: "anki-mate/manifest.lock")
        XCTAssertNil(lockFile)
    }

    func testSyncAppliesCurrentRemoteSnapshotAndDownloadsAudio() async throws {
        let store = try makeStore()
        let status = SyncStatus()
        let remoteAudio = Data([0x01, 0x02, 0x03, 0x04])
        let remoteAudioHash = SyncAudioStore.hash(remoteAudio)
        let collectionID = UUID().uuidString
        let wordID = UUID().uuidString
        let remoteManifest = SyncManifest(
            deviceId: "remote-device",
            collections: [
                SyncCollectionRecord(
                    id: collectionID,
                    name: "Remote Set",
                    dictionaryName: "ODE",
                    ankiDeckName: "Remote Deck",
                    deckDescription: "desc",
                    createdAt: 10,
                    updatedAt: 20,
                    deletedAt: nil
                )
            ],
            words: [
                SyncWordRecord(
                    id: wordID,
                    collectionId: collectionID,
                    normalizedWord: "banana",
                    displayWord: "Banana",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: 30,
                    deletedAt: nil,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: try JSONEncoder().encode(PersistedLookupState.pending).base64EncodedString(),
                        lookupRefreshedAt: 30,
                        payloadUpdatedAt: 40,
                        audioRef: remoteAudioHash,
                        aiArtifactsJSON: nil
                    )
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let client = FakeWebDAVClient(
            files: [
                "anki-mate/manifest.json": try encoder.encode(remoteManifest),
                SyncAudioStore.remotePath(for: remoteAudioHash): remoteAudio
            ]
        )

        let engine = SyncEngine(
            store: store,
            status: status,
            environment: .init(
                loadCredentials: { testWebDAVCredentials },
                makeClient: { _ in client }
            )
        )

        await engine.sync()

        let collections = try store.loadCollections()
        let words = try store.loadAllWords()
        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.only?.name, "Remote Set")
        XCTAssertEqual(words.only?.displayWord, "Banana")
        XCTAssertEqual(words.only?.audioData, remoteAudio)
        XCTAssertEqual(status.state, .idle)
        XCTAssertFalse(status.hasPendingChanges)
        XCTAssertNil(status.lastError)

        let backupPaths = await client.paths(withPrefix: "anki-mate/backups/manifest-")
        XCTAssertEqual(backupPaths.count, 1)
        XCTAssertNotNil(try store.syncMetadata(forKey: "last_sync_timestamp"))
        let lockFile = await client.file(at: "anki-mate/manifest.lock")
        XCTAssertNil(lockFile)
    }

    private func makeStore() throws -> WordListStore {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return try WordListStore(databaseURL: baseURL.appendingPathComponent("word-list.sqlite3"))
    }
}

private actor FakeWebDAVClient: WebDAVClientProtocol {
    private var files: [String: Data]
    private var directories: Set<String>

    init(files: [String: Data] = [:], directories: Set<String> = []) {
        self.files = files
        self.directories = directories
    }

    func get(_ path: String) async throws -> Data? {
        files[normalized(path)]
    }

    func put(_ path: String, data: Data, contentType: String) async throws {
        let normalizedPath = normalized(path)
        files[normalizedPath] = data
        registerParentDirectories(for: normalizedPath)
    }

    func delete(_ path: String) async throws {
        files.removeValue(forKey: normalized(path))
    }

    func mkcol(_ path: String) async throws {
        directories.insert(directoryPath(path))
    }

    func exists(_ path: String) async throws -> Bool {
        files[normalized(path)] != nil
    }

    func ensureDirectoryStructure() async throws {
        try await mkcol("anki-mate/")
        try await mkcol("anki-mate/audio/")
        try await mkcol("anki-mate/backups/")
    }

    func listFiles(in path: String) async throws -> [String] {
        let prefix = directoryPath(path)
        if prefix == "anki-mate/audio/" {
            let childDirectories = directories
                .filter { $0.hasPrefix(prefix) && $0 != prefix }
                .compactMap { candidate -> String? in
                    let remainder = String(candidate.dropFirst(prefix.count))
                    guard !remainder.isEmpty else { return nil }
                    let trimmed = remainder.hasSuffix("/") ? String(remainder.dropLast()) : remainder
                    guard !trimmed.contains("/") else { return nil }
                    return trimmed
                }
            return Array(Set(childDirectories)).sorted()
        }

        let childFiles = files.keys.compactMap { key -> String? in
            guard key.hasPrefix(prefix) else { return nil }
            let remainder = String(key.dropFirst(prefix.count))
            guard !remainder.isEmpty, !remainder.contains("/") else { return nil }
            return remainder
        }
        return childFiles.sorted()
    }

    func file(at path: String) -> Data? {
        files[normalized(path)]
    }

    func paths(withPrefix prefix: String) -> [String] {
        files.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private func normalized(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private func directoryPath(_ path: String) -> String {
        let normalizedPath = normalized(path)
        return normalizedPath.hasSuffix("/") ? normalizedPath : normalizedPath + "/"
    }

    private func registerParentDirectories(for path: String) {
        let components = path.split(separator: "/")
        guard components.count > 1 else { return }
        var current = ""
        for component in components.dropLast() {
            current += component + "/"
            directories.insert(current)
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private let testWebDAVCredentials = WebDAVCredentials(
    serverURL: "https://example.com/dav",
    username: "user",
    password: "pass"
)
