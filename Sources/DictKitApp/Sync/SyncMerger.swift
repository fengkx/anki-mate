import Foundation

/// Pure-function merge logic for sync manifests.
enum SyncMerger {
    private static let tombstoneRetentionInterval: TimeInterval = 90 * 24 * 60 * 60

    struct MergeResult {
        var mergedManifest: SyncManifest
        var collectionsToApplyLocally: [SyncCollectionRecord]
        var wordsToApplyLocally: [SyncWordRecord]
        var audioRefsToDownload: Set<String>
        var audioRefsToUpload: [String: String]
        var localCollectionTombstonesToPurge: Set<String>
        var localWordTombstonesToPurge: Set<String>
    }

    static func merge(local: SyncManifest, remote: SyncManifest?, now: TimeInterval = Date().timeIntervalSince1970) -> MergeResult {
        guard let remote else {
            let audioToUpload = Dictionary(
                uniqueKeysWithValues: local.words.compactMap { word -> (String, String)? in
                    guard !shouldPruneTombstone(local: word, remote: nil, now: now) else { return nil }
                    guard let ref = word.payload.audioRef, !word.isDeleted else { return nil }
                    return (word.id, ref)
                }
            )
            let mergedCollections = local.collections.filter { !shouldPruneTombstone(local: $0, remote: nil, now: now) }
            let mergedWords = local.words.filter { !shouldPruneTombstone(local: $0, remote: nil, now: now) }
            let localCollectionsToPurge = Set(local.collections.filter { shouldPruneTombstone(local: $0, remote: nil, now: now) }.map(\.id))
            let localWordsToPurge = Set(local.words.filter { shouldPruneTombstone(local: $0, remote: nil, now: now) }.map(\.id))
            return MergeResult(
                mergedManifest: SyncManifest(deviceId: local.deviceId, collections: mergedCollections, words: mergedWords),
                collectionsToApplyLocally: [],
                wordsToApplyLocally: [],
                audioRefsToDownload: [],
                audioRefsToUpload: audioToUpload,
                localCollectionTombstonesToPurge: localCollectionsToPurge,
                localWordTombstonesToPurge: localWordsToPurge
            )
        }

        let remoteCollections = Dictionary(uniqueKeysWithValues: remote.collections.map { ($0.id, $0) })
        let remoteWords = Dictionary(uniqueKeysWithValues: remote.words.map { ($0.id, $0) })

        let localCollections = Dictionary(uniqueKeysWithValues: local.collections.map { ($0.id, $0) })
        let localWords = Dictionary(uniqueKeysWithValues: local.words.map { ($0.id, $0) })

        var mergedCollections: [SyncCollectionRecord] = []
        var collectionsToApply: [SyncCollectionRecord] = []

        var mergedWords: [SyncWordRecord] = []
        var wordsToApply: [SyncWordRecord] = []
        var audioToDownload = Set<String>()
        var audioToUpload: [String: String] = [:]
        var localCollectionsToPurge = Set<String>()
        var localWordsToPurge = Set<String>()

        for id in Set(localCollections.keys).union(remoteCollections.keys) {
            let localCollection = localCollections[id]
            let remoteCollection = remoteCollections[id]

            let merged: SyncCollectionRecord?
            switch (localCollection, remoteCollection) {
            case let (.some(local), .some(remote)):
                merged = remote.updatedAt > local.updatedAt ? remote : local
            case let (.some(local), .none):
                merged = local
            case let (.none, .some(remote)):
                merged = remote
            case (.none, .none):
                merged = nil
            }

            guard let merged else { continue }
            if shouldPruneTombstone(local: localCollection, remote: remoteCollection, now: now, merged: merged) {
                if localCollection?.isDeleted == true {
                    localCollectionsToPurge.insert(id)
                }
                continue
            }
            mergedCollections.append(merged)
            if localCollection != merged {
                collectionsToApply.append(merged)
            }
        }

        for id in Set(localWords.keys).union(remoteWords.keys) {
            let localWord = localWords[id]
            let remoteWord = remoteWords[id]

            let merged = mergeWord(local: localWord, remote: remoteWord)
            guard let merged else { continue }
            if shouldPruneTombstone(local: localWord, remote: remoteWord, now: now, merged: merged.word) {
                if localWord?.isDeleted == true {
                    localWordsToPurge.insert(id)
                }
                continue
            }
            mergedWords.append(merged.word)

            if localWord != merged.word {
                wordsToApply.append(merged.word)
            }

            if let downloadRef = merged.audioRefToDownload {
                audioToDownload.insert(downloadRef)
            }

            if let upload = merged.audioRefToUpload {
                audioToUpload[upload.wordId] = upload.audioRef
            }
        }

        let mergedManifest = SyncManifest(
            deviceId: local.deviceId,
            collections: mergedCollections.sorted { $0.createdAt < $1.createdAt },
            words: mergedWords.sorted { $0.createdAt < $1.createdAt }
        )

        return MergeResult(
            mergedManifest: mergedManifest,
            collectionsToApplyLocally: collectionsToApply.sorted { $0.createdAt < $1.createdAt },
            wordsToApplyLocally: wordsToApply.sorted { $0.createdAt < $1.createdAt },
            audioRefsToDownload: audioToDownload,
            audioRefsToUpload: audioToUpload,
            localCollectionTombstonesToPurge: localCollectionsToPurge,
            localWordTombstonesToPurge: localWordsToPurge
        )
    }

    private static func shouldPruneTombstone(local: SyncCollectionRecord?, remote: SyncCollectionRecord?, now: TimeInterval, merged: SyncCollectionRecord? = nil) -> Bool {
        let candidate = merged ?? local ?? remote
        guard let candidate,
              candidate.isDeleted,
              let deletedAt = candidate.deletedAt,
              now - deletedAt >= tombstoneRetentionInterval else {
            return false
        }
        return !(local?.isDeleted == false || remote?.isDeleted == false)
    }

    private static func shouldPruneTombstone(local: SyncWordRecord?, remote: SyncWordRecord?, now: TimeInterval, merged: SyncWordRecord? = nil) -> Bool {
        let candidate = merged ?? local ?? remote
        guard let candidate,
              candidate.isDeleted,
              let deletedAt = candidate.deletedAt,
              now - deletedAt >= tombstoneRetentionInterval else {
            return false
        }
        return !(local?.isDeleted == false || remote?.isDeleted == false)
    }

    private static func mergeWord(local: SyncWordRecord?, remote: SyncWordRecord?) -> (word: SyncWordRecord, audioRefToDownload: String?, audioRefToUpload: (wordId: String, audioRef: String)?)? {
        switch (local, remote) {
        case let (.some(local), .some(remote)):
            let coreWinner = remote.updatedAt > local.updatedAt ? remote : local
            let payloadWinner = remote.payload.payloadUpdatedAt > local.payload.payloadUpdatedAt ? remote : local

            var merged = coreWinner
            merged.payload = payloadWinner.payload

            let downloadRef: String?
            if payloadWinner.id == remote.id,
               let ref = remote.payload.audioRef,
               ref != local.payload.audioRef,
               !remote.isDeleted {
                downloadRef = ref
            } else {
                downloadRef = nil
            }

            let uploadRef: (wordId: String, audioRef: String)?
            if payloadWinner.id == local.id,
               let ref = local.payload.audioRef,
               ref != remote.payload.audioRef,
               !local.isDeleted {
                uploadRef = (local.id, ref)
            } else {
                uploadRef = nil
            }

            return (merged, downloadRef, uploadRef)

        case let (.some(local), .none):
            let uploadRef = local.payload.audioRef.flatMap { ref in
                local.isDeleted ? nil : (local.id, ref)
            }
            return (local, nil, uploadRef)

        case let (.none, .some(remote)):
            let downloadRef = remote.payload.audioRef.flatMap { ref in
                remote.isDeleted ? nil : ref
            }
            return (remote, downloadRef, nil)

        case (.none, .none):
            return nil
        }
    }
}
