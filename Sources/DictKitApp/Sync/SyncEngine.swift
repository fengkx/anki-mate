import Foundation

final class SyncEngine {
    private let store: WordListStore
    private let status: SyncStatus
    private let onStoreChanged: @MainActor () -> Void
    private let environment: Environment

    private var deviceId: String = ""

    struct Environment {
        var loadCredentials: @Sendable () -> WebDAVCredentials
        var makeClient: @Sendable (WebDAVCredentials) throws -> any WebDAVClientProtocol

        static let live = Environment(
            loadCredentials: { WebDAVCredentials.load() },
            makeClient: { credentials in try WebDAVClient(credentials: credentials) }
        )
    }

    init(
        store: WordListStore,
        status: SyncStatus,
        environment: Environment = .live,
        onStoreChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.status = status
        self.environment = environment
        self.onStoreChanged = onStoreChanged
    }

    @MainActor
    func refreshPendingStatus() {
        if let hasPending = try? store.hasChangesAfterLastSync() {
            status.hasPendingChanges = hasPending
        }
    }

    @MainActor
    func sync() async {
        guard status.state == .idle || status.state == .error else { return }
        status.state = .syncing(phase: "Preparing...")

        do {
            let credentials = environment.loadCredentials()
            guard credentials.isConfigured else {
                status.state = .idle
                return
            }
            let client = try environment.makeClient(credentials)
            deviceId = try loadOrCreateDeviceId()
            let bootstrapLocalState = try store.isBootstrapLocalState()

            updatePhase("Connecting...")
            try await client.ensureDirectoryStructure()

            try await withManifestLock(client: client) {
                updatePhase("Downloading manifest...")
                let remote = try await pullManifest(client: client)

                if case .legacy(let legacyManifest) = remote {
                    updatePhase("Upgrading remote state...")
                    try await backupLegacyManifest(client: client)
                    let upgradedRemote = SyncManifest(legacyManifest: legacyManifest)
                    let audioData = try await downloadAudioIfNeeded(for: upgradedRemote.words, client: client)
                    if bootstrapLocalState {
                        try store.resetLocalSyncContent()
                    }
                    try store.applySyncBatch(
                        collections: upgradedRemote.collections,
                        words: upgradedRemote.words,
                        audioData: audioData
                    )
                    try await pushManifest(upgradedRemote, client: client)
                    try store.setSyncMetadata(String(Date().timeIntervalSince1970), forKey: "last_sync_timestamp")

                    status.state = .idle
                    status.lastSyncDate = Date()
                    status.lastError = nil
                    status.hasPendingChanges = false
                    onStoreChanged()
                    return
                }

                updatePhase("Building local state...")
                let localManifest: SyncManifest
                if bootstrapLocalState {
                    localManifest = SyncManifest(deviceId: deviceId, collections: [], words: [])
                } else {
                    localManifest = try buildLocalManifest()
                }
                let remoteManifest: SyncManifest?
                if case .current(let manifest) = remote {
                    remoteManifest = manifest
                } else {
                    remoteManifest = nil
                }

                updatePhase("Merging...")
                let mergeResult = SyncMerger.merge(local: localManifest, remote: remoteManifest)

                if !mergeResult.audioRefsToDownload.isEmpty || !mergeResult.collectionsToApplyLocally.isEmpty || !mergeResult.wordsToApplyLocally.isEmpty {
                    let audioData = try await downloadAudioIfNeeded(for: mergeResult.wordsToApplyLocally, refs: mergeResult.audioRefsToDownload, client: client)
                    updatePhase("Applying changes...")
                    if bootstrapLocalState, remoteManifest != nil {
                        try store.resetLocalSyncContent()
                    }
                    try store.applySyncBatch(
                        collections: mergeResult.collectionsToApplyLocally,
                        words: mergeResult.wordsToApplyLocally,
                        audioData: audioData
                    )
                }

                if !mergeResult.audioRefsToUpload.isEmpty {
                    updatePhase("Uploading audio (\(mergeResult.audioRefsToUpload.count))...")
                    for (wordId, ref) in mergeResult.audioRefsToUpload {
                        guard let uuid = UUID(uuidString: wordId),
                              let audioData = try store.audioData(forWordId: uuid) else { continue }
                        try await SyncAudioStore.upload(hash: ref, data: audioData, client: client)
                    }
                }

                updatePhase("Uploading manifest...")
                try await pushManifest(mergeResult.mergedManifest, client: client)
                try? await backupManifest(client: client)
                try? await cleanOrphanAudioIfNeeded(manifest: mergeResult.mergedManifest, client: client)
                try store.purgeLocalTombstones(
                    collectionIDs: mergeResult.localCollectionTombstonesToPurge,
                    wordIDs: mergeResult.localWordTombstonesToPurge
                )

                let ts = String(Date().timeIntervalSince1970)
                try store.setSyncMetadata(ts, forKey: "last_sync_timestamp")

                status.state = .idle
                status.lastSyncDate = Date()
                status.lastError = nil
                status.hasPendingChanges = false

                if !mergeResult.collectionsToApplyLocally.isEmpty || !mergeResult.wordsToApplyLocally.isEmpty {
                    onStoreChanged()
                }
            }
        } catch {
            status.state = .error
            status.lastError = error.localizedDescription
        }
    }

    private func buildLocalManifest() throws -> SyncManifest {
        let collections = try store.loadAllCollectionsForSync().map { snapshot in
            SyncCollectionRecord(
                id: snapshot.record.id.uuidString,
                name: snapshot.record.name,
                dictionaryName: snapshot.record.dictionaryName,
                deckDescription: snapshot.record.ankiDeckDescription,
                createdAt: snapshot.record.createdAt.timeIntervalSince1970,
                updatedAt: snapshot.record.updatedAt.timeIntervalSince1970,
                deletedAt: snapshot.deletedAt?.timeIntervalSince1970
            )
        }

        let words = try store.loadAllWordsForSync().map { snapshot in
            let lookupBase64 = try? JSONEncoder().encode(snapshot.record.lookupState).base64EncodedString()
            let audioRef: String? = {
                if let hash = snapshot.audioHash { return hash }
                guard let audioData = snapshot.record.audioData else { return nil }
                return SyncAudioStore.hash(audioData)
            }()

            return SyncWordRecord(
                id: snapshot.record.id.uuidString,
                collectionId: snapshot.collectionId.uuidString,
                normalizedWord: snapshot.record.normalizedWord,
                displayWord: snapshot.record.displayWord,
                sourceForm: snapshot.record.sourceForm,
                inflectionKind: snapshot.record.inflectionKind?.rawValue,
                expectedPartOfSpeech: snapshot.record.expectedPartOfSpeech?.rawValue,
                createdAt: snapshot.record.createdAt.timeIntervalSince1970,
                updatedAt: snapshot.record.updatedAt.timeIntervalSince1970,
                deletedAt: snapshot.deletedAt?.timeIntervalSince1970,
                payload: SyncWordPayloadRecord(
                    lookupStateBase64: lookupBase64,
                    lookupRefreshedAt: snapshot.record.lastRefreshedAt?.timeIntervalSince1970,
                    payloadUpdatedAt: snapshot.payloadUpdatedAt.timeIntervalSince1970,
                    audioRef: audioRef,
                    aiArtifactsJSON: try? store.encodeAIArtifacts(snapshot.record.aiArtifacts)
                )
            )
        }

        return SyncManifest(deviceId: deviceId, collections: collections, words: words)
    }

    private func pullManifest(client: any WebDAVClientProtocol) async throws -> PulledManifest? {
        guard let data = try await client.get("anki-mate/manifest.json") else {
            return nil
        }
        if let manifest = try? JSONDecoder().decode(SyncManifest.self, from: data),
           manifest.format == SyncManifest.currentFormat {
            return .current(manifest)
        }
        return .legacy(try JSONDecoder().decode(LegacySyncManifest.self, from: data))
    }

    private func pushManifest(_ manifest: SyncManifest, client: any WebDAVClientProtocol) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try await client.put("anki-mate/manifest.json", data: data, contentType: "application/json")
    }

    private func backupLegacyManifest(client: any WebDAVClientProtocol) async throws {
        guard let data = try await client.get("anki-mate/manifest.json") else { return }
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        try await client.put(
            "anki-mate/backups/manifest-v1-\(timestamp).json",
            data: data,
            contentType: "application/json"
        )
    }

    private func backupManifest(client: any WebDAVClientProtocol) async throws {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        if let data = try await client.get("anki-mate/manifest.json") {
            try await client.put("anki-mate/backups/manifest-\(timestamp).json", data: data, contentType: "application/json")
        }
    }

    private func cleanOrphanAudioIfNeeded(manifest: SyncManifest, client: any WebDAVClientProtocol) async throws {
        let cleanupInterval: TimeInterval = 7 * 24 * 3600
        if let lastCleanup = try store.syncMetadata(forKey: "last_orphan_cleanup"),
           let ts = TimeInterval(lastCleanup),
           Date().timeIntervalSince1970 - ts < cleanupInterval {
            return
        }

        let referencedRefs = Set(manifest.words.compactMap(\.payload.audioRef))
        let prefixDirs = try await client.listFiles(in: "anki-mate/audio/")
        let knownPrefixes = Set(referencedRefs.map { String($0.prefix(2)) })
        let allPrefixes = knownPrefixes.union(Set(prefixDirs))

        var allRemoteHashes = Set<String>()
        for prefix in allPrefixes {
            let files = try await client.listFiles(in: "anki-mate/audio/\(prefix)/")
            for file in files {
                allRemoteHashes.insert(file.hasSuffix(".wav") ? String(file.dropLast(4)) : file)
            }
        }

        for hash in allRemoteHashes.subtracting(referencedRefs) {
            try await client.delete(SyncAudioStore.remotePath(for: hash))
        }

        try store.setSyncMetadata(String(Date().timeIntervalSince1970), forKey: "last_orphan_cleanup")
    }

    private func acquireLock(client: any WebDAVClientProtocol) async throws {
        let lockPath = "anki-mate/manifest.lock"
        if let lockData = try await client.get(lockPath),
           let lockInfo = try? JSONDecoder().decode(LockInfo.self, from: lockData) {
            let age = Date().timeIntervalSince1970 - lockInfo.lockedAt
            if age < 120 {
                throw WebDAVError.locked
            }
        }
        let lockInfo = LockInfo(deviceId: deviceId, lockedAt: Date().timeIntervalSince1970)
        try await client.put(lockPath, data: try JSONEncoder().encode(lockInfo), contentType: "application/json")
    }

    private func releaseLock(client: any WebDAVClientProtocol) async throws {
        try await client.delete("anki-mate/manifest.lock")
    }

    @MainActor
    private func withManifestLock(
        client: any WebDAVClientProtocol,
        operation: () async throws -> Void
    ) async throws {
        updatePhase("Acquiring lock...")
        try await acquireLock(client: client)
        do {
            try await operation()
            try await releaseLock(client: client)
        } catch {
            try? await releaseLock(client: client)
            throw error
        }
    }

    private func loadOrCreateDeviceId() throws -> String {
        if let existing = try store.syncMetadata(forKey: "device_id") {
            return existing
        }
        let newId = UUID().uuidString
        try store.setSyncMetadata(newId, forKey: "device_id")
        return newId
    }

    private func downloadAudioIfNeeded(for words: [SyncWordRecord], refs: Set<String>? = nil, client: any WebDAVClientProtocol) async throws -> [String: Data] {
        let targetRefs = refs ?? Set(words.compactMap(\.payload.audioRef))
        var audioData: [String: Data] = [:]
        for ref in targetRefs {
            if let data = try await SyncAudioStore.download(hash: ref, client: client) {
                audioData[ref] = data
            }
        }
        return audioData
    }

    @MainActor
    private func updatePhase(_ phase: String) {
        status.state = .syncing(phase: phase)
    }
}

private struct LockInfo: Codable {
    let deviceId: String
    let lockedAt: TimeInterval
}

extension SyncManifest {
    init(legacyManifest: LegacySyncManifest) {
        self.init(
            deviceId: legacyManifest.deviceId,
            collections: legacyManifest.collections.map { record in
                SyncCollectionRecord(
                    id: record.id,
                    name: record.name,
                    dictionaryName: record.dictionaryName,
                    deckDescription: record.deckDescription,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    deletedAt: record.isDeleted ? record.updatedAt : nil
                )
            },
            words: legacyManifest.words.map { record in
                SyncWordRecord(
                    id: record.id,
                    collectionId: record.collectionId,
                    normalizedWord: record.normalizedWord,
                    displayWord: record.displayWord,
                    sourceForm: record.sourceForm,
                    inflectionKind: record.inflectionKind,
                    expectedPartOfSpeech: record.expectedPartOfSpeech,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    deletedAt: record.isDeleted ? record.updatedAt : nil,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: record.lookupStateBase64,
                        lookupRefreshedAt: record.lastRefreshedAt,
                        payloadUpdatedAt: record.updatedAt,
                        audioRef: record.audioRef,
                        aiArtifactsJSON: nil
                    )
                )
            }
        )
    }
}
