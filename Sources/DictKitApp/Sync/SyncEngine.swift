import Foundation

/// Orchestrates the full sync flow: pull → merge → apply → push.
final class SyncEngine {
    private let store: WordListStore
    private let status: SyncStatus
    private let onStoreChanged: @MainActor () -> Void

    private var deviceId: String = ""

    init(
        store: WordListStore,
        status: SyncStatus,
        onStoreChanged: @escaping @MainActor () -> Void = {}
    ) {
        self.store = store
        self.status = status
        self.onStoreChanged = onStoreChanged
    }

    // MARK: - Public

    /// Check if there are local changes not yet synced and update status.
    @MainActor
    func refreshPendingStatus() {
        if let hasPending = try? store.hasChangesAfterLastSync() {
            status.hasPendingChanges = hasPending
        }
    }

    /// Run a full sync cycle.
    @MainActor
    func sync() async {
        guard status.state == .idle || status.state == .error else { return }
        status.state = .syncing(phase: "Preparing...")
        var didApplyRemoteChanges = false

        do {
            let credentials = WebDAVCredentials.load()
            guard credentials.isConfigured else {
                status.state = .idle
                return
            }
            let client = try WebDAVClient(credentials: credentials)

            // Load or create device ID
            deviceId = try loadOrCreateDeviceId()

            await updatePhase("Connecting...")
            try await client.ensureDirectoryStructure()

            // 1. Acquire lock
            await updatePhase("Acquiring lock...")
            try await acquireLock(client: client)

            defer {
                Task { try? await self.releaseLock(client: client) }
            }

            // 2. Pull remote manifest
            await updatePhase("Downloading manifest...")
            let remoteManifest = try await pullManifest(client: client)

            // 3. Build local manifest
            await updatePhase("Building local state...")
            let localManifest = try buildLocalManifest()

            // 4. Merge
            await updatePhase("Merging...")
            let mergeResult = SyncMerger.merge(local: localManifest, remote: remoteManifest)

            // 5. Download new audio from remote
            if !mergeResult.audioRefsToDownload.isEmpty {
                await updatePhase("Downloading audio (\(mergeResult.audioRefsToDownload.count))...")
                var audioData: [String: Data] = [:]
                for ref in mergeResult.audioRefsToDownload {
                    if let data = try await SyncAudioStore.download(hash: ref, client: client) {
                        audioData[ref] = data
                    }
                }

                // 6. Apply remote changes locally
                await updatePhase("Applying changes...")
                try store.applySyncBatch(
                    collections: mergeResult.collectionsToApplyLocally,
                    words: mergeResult.wordsToApplyLocally,
                    audioData: audioData
                )
                didApplyRemoteChanges = true
            } else if !mergeResult.collectionsToApplyLocally.isEmpty || !mergeResult.wordsToApplyLocally.isEmpty {
                await updatePhase("Applying changes...")
                try store.applySyncBatch(
                    collections: mergeResult.collectionsToApplyLocally,
                    words: mergeResult.wordsToApplyLocally,
                    audioData: [:]
                )
                didApplyRemoteChanges = true
            }

            // 7. Upload new local audio
            if !mergeResult.audioRefsToUpload.isEmpty {
                await updatePhase("Uploading audio (\(mergeResult.audioRefsToUpload.count))...")
                for (wordId, ref) in mergeResult.audioRefsToUpload {
                    guard let uuid = UUID(uuidString: wordId) else { continue }
                    if let audioData = try store.audioData(forWordId: uuid) {
                        try await SyncAudioStore.upload(hash: ref, data: audioData, client: client)
                    }
                }
            }

            // 8. Push merged manifest
            await updatePhase("Uploading manifest...")
            try await pushManifest(mergeResult.mergedManifest, client: client)

            // 9. Backup (best-effort)
            try? await backupManifest(client: client)

            // 10. Orphan audio cleanup (best-effort, every 7 days)
            try? await cleanOrphanAudioIfNeeded(manifest: mergeResult.mergedManifest, client: client)

            // 11. Update sync timestamp
            let ts = String(Date().timeIntervalSince1970)
            try store.setSyncMetadata(ts, forKey: "last_sync_timestamp")

            await MainActor.run {
                status.state = .idle
                status.lastSyncDate = Date()
                status.lastError = nil
                status.hasPendingChanges = false
            }

            if didApplyRemoteChanges {
                onStoreChanged()
            }
        } catch {
            await MainActor.run {
                status.state = .error
                status.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Manifest

    private func buildLocalManifest() throws -> SyncManifest {
        let allCollections = try store.loadAllCollectionsForSync()
        let allWords = try store.loadAllWordsForSync()

        let syncCollections = allCollections.map { (record, isDeleted) in
            SyncCollectionRecord(
                id: record.id.uuidString,
                name: record.name,
                dictionaryName: record.dictionaryName,
                ankiDeckName: record.ankiDeckName,
                deckDescription: record.ankiDeckDescription,
                createdAt: record.createdAt.timeIntervalSince1970,
                updatedAt: record.updatedAt.timeIntervalSince1970,
                isDeleted: isDeleted
            )
        }

        let syncWords = allWords.map { (record, collectionId, isDeleted, audioHash) in
            let lookupBase64: String? = {
                guard case .loaded = record.lookupState else { return nil }
                if let data = try? JSONEncoder().encode(record.lookupState) {
                    return data.base64EncodedString()
                }
                return nil
            }()

            // Compute audio hash if needed
            let ref: String? = {
                if let hash = audioHash { return hash }
                if let audio = record.audioData {
                    let hash = SyncAudioStore.hash(audio)
                    // Best-effort: update the hash in DB (ignore errors)
                    _ = try? store.updateAudioHash(forWordId: record.id, audioData: audio)
                    return hash
                }
                return nil
            }()

            return SyncWordRecord(
                id: record.id.uuidString,
                collectionId: collectionId.uuidString,
                normalizedWord: record.normalizedWord,
                displayWord: record.displayWord,
                sourceForm: record.sourceForm,
                inflectionKind: record.inflectionKind?.rawValue,
                expectedPartOfSpeech: record.expectedPartOfSpeech?.rawValue,
                lookupStateBase64: lookupBase64,
                audioRef: ref,
                createdAt: record.createdAt.timeIntervalSince1970,
                updatedAt: record.updatedAt.timeIntervalSince1970,
                lastRefreshedAt: record.lastRefreshedAt?.timeIntervalSince1970,
                isDeleted: isDeleted
            )
        }

        return SyncManifest(
            deviceId: deviceId,
            collections: syncCollections,
            words: syncWords
        )
    }

    private func pullManifest(client: WebDAVClient) async throws -> SyncManifest? {
        guard let data = try await client.get("anki-mate/manifest.json") else {
            return nil
        }
        return try JSONDecoder().decode(SyncManifest.self, from: data)
    }

    private func pushManifest(_ manifest: SyncManifest, client: WebDAVClient) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try await client.put("anki-mate/manifest.json", data: data, contentType: "application/json")
    }

    private func backupManifest(client: WebDAVClient) async throws {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        // Copy current manifest to backup
        if let data = try await client.get("anki-mate/manifest.json") {
            try await client.put("anki-mate/backups/manifest-\(timestamp).json", data: data, contentType: "application/json")
        }
    }

    // MARK: - Orphan audio cleanup

    private func cleanOrphanAudioIfNeeded(manifest: SyncManifest, client: WebDAVClient) async throws {
        // Check if 7 days have passed since last cleanup
        let cleanupInterval: TimeInterval = 7 * 24 * 3600
        if let lastCleanup = try store.syncMetadata(forKey: "last_orphan_cleanup"),
           let ts = TimeInterval(lastCleanup),
           Date().timeIntervalSince1970 - ts < cleanupInterval {
            return
        }

        // Collect all referenced audio hashes
        let referencedRefs = Set(manifest.words.compactMap(\.audioRef))

        // List all audio prefix directories (00-ff)
        let prefixDirs = try await client.listFiles(in: "anki-mate/audio/")
        // listFiles returns file names; for directories we need to also check sub-items
        // Actually, prefix dirs show up as entries too. Let's iterate known 2-char hex prefixes
        // that we can infer from referenced refs, plus scan for any extra files
        var allRemoteHashes = Set<String>()

        // Scan each prefix directory that might exist
        let knownPrefixes = Set(referencedRefs.map { String($0.prefix(2)) })
        // Also check all prefixes returned by PROPFIND
        let allPrefixes = knownPrefixes.union(Set(prefixDirs))

        for prefix in allPrefixes {
            let files = try await client.listFiles(in: "anki-mate/audio/\(prefix)/")
            for file in files {
                // Extract hash from filename (remove .wav extension)
                let hash = file.hasSuffix(".wav") ? String(file.dropLast(4)) : file
                allRemoteHashes.insert(hash)
            }
        }

        // Find orphans: remote hashes not in referenced set
        let orphans = allRemoteHashes.subtracting(referencedRefs)
        for hash in orphans {
            let path = SyncAudioStore.remotePath(for: hash)
            try await client.delete(path)
        }

        // Record cleanup time
        try store.setSyncMetadata(String(Date().timeIntervalSince1970), forKey: "last_orphan_cleanup")
    }

    // MARK: - Lock

    private func acquireLock(client: WebDAVClient) async throws {
        let lockPath = "anki-mate/manifest.lock"
        // Check existing lock
        if let lockData = try await client.get(lockPath) {
            if let lockInfo = try? JSONDecoder().decode(LockInfo.self, from: lockData) {
                let age = Date().timeIntervalSince1970 - lockInfo.lockedAt
                if age < 120 {
                    // Lock is fresh — abort
                    throw WebDAVError.locked
                }
                // Lock is stale — steal it
            }
        }
        // Create lock
        let lockInfo = LockInfo(deviceId: deviceId, lockedAt: Date().timeIntervalSince1970)
        let data = try JSONEncoder().encode(lockInfo)
        try await client.put(lockPath, data: data, contentType: "application/json")
    }

    private func releaseLock(client: WebDAVClient) async throws {
        try await client.delete("anki-mate/manifest.lock")
    }

    // MARK: - Device ID

    private func loadOrCreateDeviceId() throws -> String {
        if let existing = try store.syncMetadata(forKey: "device_id") {
            return existing
        }
        let newId = UUID().uuidString
        try store.setSyncMetadata(newId, forKey: "device_id")
        return newId
    }

    // MARK: - Helpers

    @MainActor
    private func updatePhase(_ phase: String) {
        status.state = .syncing(phase: phase)
    }
}

private struct LockInfo: Codable {
    let deviceId: String
    let lockedAt: TimeInterval
}
