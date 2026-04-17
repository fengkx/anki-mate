import Foundation

/// Pure-function merge logic for sync manifests.
enum SyncMerger {

    struct MergeResult {
        /// The unified manifest to push to remote.
        var mergedManifest: SyncManifest
        /// Collections that need to be applied to the local store (new or updated from remote).
        var collectionsToApplyLocally: [SyncCollectionRecord]
        /// Words that need to be applied to the local store (new or updated from remote).
        var wordsToApplyLocally: [SyncWordRecord]
        /// Audio refs that need to be downloaded from remote (new/changed remote audio).
        var audioRefsToDownload: Set<String>
        /// Word IDs whose audio needs to be uploaded (new/changed local audio). Maps wordId → audioRef.
        var audioRefsToUpload: [String: String]
    }

    /// Merge local and remote manifests using last-writer-wins on `updatedAt`.
    ///
    /// - Parameters:
    ///   - local: The manifest built from the local SQLite state.
    ///   - remote: The manifest fetched from WebDAV. Nil on first sync.
    /// - Returns: A `MergeResult` describing what to apply locally, what to push, and what audio to transfer.
    static func merge(local: SyncManifest, remote: SyncManifest?) -> MergeResult {
        guard let remote else {
            // First sync: everything is local, push all
            let audioToUpload = Dictionary(
                uniqueKeysWithValues: local.words.compactMap { word -> (String, String)? in
                    guard let ref = word.audioRef, !word.isDeleted else { return nil }
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

        // Index remote records by ID
        let remoteCollections = Dictionary(uniqueKeysWithValues: remote.collections.map { ($0.id, $0) })
        let remoteWords = Dictionary(uniqueKeysWithValues: remote.words.map { ($0.id, $0) })

        // Index local records by ID
        let localCollections = Dictionary(uniqueKeysWithValues: local.collections.map { ($0.id, $0) })
        let localWords = Dictionary(uniqueKeysWithValues: local.words.map { ($0.id, $0) })

        var mergedCollections: [SyncCollectionRecord] = []
        var collectionsToApply: [SyncCollectionRecord] = []

        var mergedWords: [SyncWordRecord] = []
        var wordsToApply: [SyncWordRecord] = []
        var audioToDownload = Set<String>()
        var audioToUpload: [String: String] = [:]

        // All known collection IDs
        let allCollectionIds = Set(localCollections.keys).union(remoteCollections.keys)
        for id in allCollectionIds {
            let localCol = localCollections[id]
            let remoteCol = remoteCollections[id]

            switch (localCol, remoteCol) {
            case let (.some(l), .some(r)):
                if r.updatedAt > l.updatedAt {
                    // Remote wins
                    mergedCollections.append(r)
                    collectionsToApply.append(r)
                } else {
                    // Local wins (or equal)
                    mergedCollections.append(l)
                }
            case let (.some(l), .none):
                // Only local
                mergedCollections.append(l)
            case let (.none, .some(r)):
                // Only remote — apply locally
                mergedCollections.append(r)
                collectionsToApply.append(r)
            case (.none, .none):
                break
            }
        }

        // All known word IDs
        let allWordIds = Set(localWords.keys).union(remoteWords.keys)
        for id in allWordIds {
            let localWord = localWords[id]
            let remoteWord = remoteWords[id]

            switch (localWord, remoteWord) {
            case let (.some(l), .some(r)):
                if r.updatedAt > l.updatedAt {
                    // Remote wins
                    mergedWords.append(r)
                    wordsToApply.append(r)
                    // Check if audio changed
                    if let ref = r.audioRef, ref != l.audioRef {
                        audioToDownload.insert(ref)
                    }
                } else {
                    // Local wins (or equal)
                    mergedWords.append(l)
                    // If local has new audio not yet on remote, upload it
                    if let ref = l.audioRef, ref != r.audioRef, !l.isDeleted {
                        audioToUpload[l.id] = ref
                    }
                }
            case let (.some(l), .none):
                // Only local — push
                mergedWords.append(l)
                if let ref = l.audioRef, !l.isDeleted {
                    audioToUpload[l.id] = ref
                }
            case let (.none, .some(r)):
                // Only remote — apply locally
                mergedWords.append(r)
                wordsToApply.append(r)
                if let ref = r.audioRef, !r.isDeleted {
                    audioToDownload.insert(ref)
                }
            case (.none, .none):
                break
            }
        }

        let merged = SyncManifest(
            deviceId: local.deviceId,
            collections: mergedCollections,
            words: mergedWords
        )

        return MergeResult(
            mergedManifest: merged,
            collectionsToApplyLocally: collectionsToApply,
            wordsToApplyLocally: wordsToApply,
            audioRefsToDownload: audioToDownload,
            audioRefsToUpload: audioToUpload
        )
    }
}
