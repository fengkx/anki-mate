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

    func testSyncDoesNotFinishUntilRemoteLockIsReleased() async throws {
        let store = try makeStore()
        let status = SyncStatus()
        let client = DelayedDeleteWebDAVClient(
            files: [
                "anki-mate/manifest.json": try JSONEncoder().encode(
                    SyncManifest(deviceId: "remote-device", collections: [], words: [])
                )
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
        let completion = AsyncCompletionFlag()

        let syncTask = Task {
            await engine.sync()
            await completion.markCompleted()
        }
        await client.waitUntilDeleteStarts()

        try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
        let deletePending = await client.isDeletePending()
        let syncCompleted = await completion.isCompleted()
        XCTAssertTrue(deletePending)
        XCTAssertFalse(syncCompleted)

        await client.finishDelete()
        await syncTask.value
        XCTAssertEqual(status.state, .idle)
    }

    func testSyncPrunesExpiredTombstonesFromUploadedManifest() async throws {
        let store = try makeStore()
        let status = SyncStatus()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let deletedCollection = try store.createCollection(
            name: "Reading",
            exportSettings: CollectionExportSettings(deckDescription: ""),
            dictionaryName: ""
        )
        let deletedWord = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .pending,
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )

        _ = try store.upsertWord(deletedWord, into: deletedCollection.id)
        try store.deleteCollection(id: deletedCollection.id)
        let tombstoneAt = Date().timeIntervalSince1970 - (90 * 24 * 60 * 60) - 1
        try store.withDatabase { db in
            try WordListStore.exec(
                db: db,
                sql: """
                UPDATE collections
                SET updated_at = \(tombstoneAt), deleted_at = \(tombstoneAt)
                WHERE id = '\(deletedCollection.id.uuidString)'
                """
            )
            try WordListStore.exec(
                db: db,
                sql: """
                UPDATE words
                SET updated_at = \(tombstoneAt), deleted_at = \(tombstoneAt)
                WHERE id = '\(deletedWord.id.uuidString)'
                """
            )
        }
        try store.setSyncMetadata("1", forKey: "last_sync_timestamp")

        let client = FakeWebDAVClient(
            files: [
                "anki-mate/manifest.json": try JSONEncoder().encode(
                    SyncManifest(deviceId: "remote-device", collections: [], words: [])
                )
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

        let uploadedData = await client.file(at: "anki-mate/manifest.json")
        let unwrappedUploadedData = try XCTUnwrap(uploadedData)
        let uploadedManifest = try JSONDecoder().decode(SyncManifest.self, from: unwrappedUploadedData)

        XCTAssertFalse(uploadedManifest.collections.contains { $0.id == deletedCollection.id.uuidString })
        XCTAssertFalse(uploadedManifest.words.contains { $0.id == deletedWord.id.uuidString })
        XCTAssertEqual(status.state, .idle)
        XCTAssertNil(status.lastError)

        let syncCollectionSnapshots = try store.loadAllCollectionsForSync()
        let syncWordSnapshots = try store.loadAllWordsForSync()
        XCTAssertEqual(syncCollectionSnapshots.count, 1)
        XCTAssertEqual(syncCollectionSnapshots.only?.record.id, collection.id)
        XCTAssertEqual(syncCollectionSnapshots.only?.deletedAt, nil)
        XCTAssertFalse(syncWordSnapshots.contains { $0.record.id == deletedWord.id })
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

private actor DelayedDeleteWebDAVClient: WebDAVClientProtocol {
    private let base: FakeWebDAVClient
    private var deleteStartedContinuation: CheckedContinuation<Void, Never>?
    private var finishDeleteContinuation: CheckedContinuation<Void, Never>?
    private var deleteStarted = false

    init(files: [String: Data] = [:], directories: Set<String> = []) {
        self.base = FakeWebDAVClient(files: files, directories: directories)
    }

    func get(_ path: String) async throws -> Data? {
        try await base.get(path)
    }

    func put(_ path: String, data: Data, contentType: String) async throws {
        try await base.put(path, data: data, contentType: contentType)
    }

    func delete(_ path: String) async throws {
        deleteStarted = true
        deleteStartedContinuation?.resume()
        deleteStartedContinuation = nil
        await withCheckedContinuation { continuation in
            finishDeleteContinuation = continuation
        }
        try await base.delete(path)
    }

    func mkcol(_ path: String) async throws {
        try await base.mkcol(path)
    }

    func exists(_ path: String) async throws -> Bool {
        try await base.exists(path)
    }

    func ensureDirectoryStructure() async throws {
        try await base.ensureDirectoryStructure()
    }

    func listFiles(in path: String) async throws -> [String] {
        try await base.listFiles(in: path)
    }

    func waitUntilDeleteStarts() async {
        guard !deleteStarted else { return }
        await withCheckedContinuation { continuation in
            deleteStartedContinuation = continuation
        }
    }

    func isDeletePending() -> Bool {
        finishDeleteContinuation != nil
    }

    func finishDelete() {
        finishDeleteContinuation?.resume()
        finishDeleteContinuation = nil
    }
}

private actor AsyncCompletionFlag {
    private var completed = false

    func markCompleted() {
        completed = true
    }

    func isCompleted() -> Bool {
        completed
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
