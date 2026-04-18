import Foundation

/// Pure-function merge logic for sync manifests.
enum SyncMerger {

    struct MergeResult {
        var mergedManifest: SyncManifest
        var collectionsToApplyLocally: [SyncCollectionRecord]
        var wordsToApplyLocally: [SyncWordRecord]
        var audioRefsToDownload: Set<String>
        var audioRefsToUpload: [String: String]
    }

    static func merge(local: SyncManifest, remote: SyncManifest?) -> MergeResult {
        guard let remote else {
            let audioToUpload = Dictionary(
                uniqueKeysWithValues: local.words.compactMap { word -> (String, String)? in
                    guard let ref = word.payload.audioRef, !word.isDeleted else { return nil }
                    return (word.id, ref)
                }
            )
            return MergeResult(
                mergedManifest: local,
                collectionsToApplyLocally: [],
                wordsToApplyLocally: [],
                audioRefsToDownload: [],
                audioRefsToUpload: audioToUpload
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
            audioRefsToUpload: audioToUpload
        )
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
