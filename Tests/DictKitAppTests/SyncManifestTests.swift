import XCTest
@testable import DictKitApp

final class SyncManifestTests: XCTestCase {
    func testSyncWhitelistExcludesAgentTables() {
        XCTAssertEqual(WordListStore.syncWhitelistedTableNames, ["collections", "words", "word_payloads"])
        XCTAssertFalse(WordListStore.syncWhitelistedTableNames.contains("agent_sessions"))
        XCTAssertFalse(WordListStore.syncWhitelistedTableNames.contains("agent_messages"))
    }

    func testLegacyManifestUpgradeMapsDeletesAndPayloads() {
        let legacy = LegacySyncManifest(
            version: 1,
            deviceId: "legacy-device",
            lastSyncedAt: 123,
            collections: [
                LegacySyncCollectionRecord(
                    id: "col-1",
                    name: "Reading",
                    dictionaryName: "ODE",
                    deckDescription: "desc",
                    createdAt: 10,
                    updatedAt: 20,
                    isDeleted: true
                )
            ],
            words: [
                LegacySyncWordRecord(
                    id: "word-1",
                    collectionId: "col-1",
                    normalizedWord: "apple",
                    displayWord: "Apple",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    lookupStateBase64: "e30=",
                    audioRef: "abcdef",
                    createdAt: 10,
                    updatedAt: 30,
                    lastRefreshedAt: 25,
                    isDeleted: true
                )
            ]
        )

        let upgraded = SyncManifest(legacyManifest: legacy)

        XCTAssertEqual(upgraded.format, SyncManifest.currentFormat)
        XCTAssertEqual(upgraded.version, SyncManifest.currentVersion)
        XCTAssertEqual(upgraded.collections.first?.deletedAt, 20)
        XCTAssertEqual(upgraded.words.first?.deletedAt, 30)
        XCTAssertEqual(upgraded.words.first?.payload.payloadUpdatedAt, 30)
        XCTAssertEqual(upgraded.words.first?.payload.lookupRefreshedAt, 25)
        XCTAssertEqual(upgraded.words.first?.payload.audioRef, "abcdef")
    }

    func testMergeUsesIndependentPayloadTimestamp() {
        let local = SyncManifest(
            deviceId: "local",
            collections: [],
            words: [
                SyncWordRecord(
                    id: "word-1",
                    collectionId: "col-1",
                    normalizedWord: "apple",
                    displayWord: "Apple",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: 20,
                    deletedAt: nil,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: "bG9jYWw=",
                        lookupRefreshedAt: 20,
                        payloadUpdatedAt: 50,
                        audioRef: "local-audio",
                        aiArtifactsJSON: "{\"schemaVersion\":2}"
                    )
                )
            ]
        )
        let remote = SyncManifest(
            deviceId: "remote",
            collections: [],
            words: [
                SyncWordRecord(
                    id: "word-1",
                    collectionId: "col-2",
                    normalizedWord: "apple",
                    displayWord: "Apple Remote",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: 40,
                    deletedAt: nil,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: "cmVtb3Rl",
                        lookupRefreshedAt: 40,
                        payloadUpdatedAt: 30,
                        audioRef: "remote-audio",
                        aiArtifactsJSON: nil
                    )
                )
            ]
        )

        let merge = SyncMerger.merge(local: local, remote: remote)
        let word = try! XCTUnwrap(merge.mergedManifest.words.first)

        XCTAssertEqual(word.collectionId, "col-2")
        XCTAssertEqual(word.displayWord, "Apple Remote")
        XCTAssertEqual(word.payload.audioRef, "local-audio")
        XCTAssertEqual(word.payload.payloadUpdatedAt, 50)
        XCTAssertTrue(merge.audioRefsToUpload.values.contains("local-audio"))
        XCTAssertTrue(merge.wordsToApplyLocally.contains(word))
    }

    func testMergePrunesExpiredTombstonesWithoutActiveCounterpart() {
        let now: TimeInterval = 200 * 24 * 60 * 60
        let deletedAt = now - (90 * 24 * 60 * 60) - 1
        let collectionID = "col-1"
        let wordID = "word-1"
        let local = SyncManifest(
            deviceId: "local",
            collections: [
                SyncCollectionRecord(
                    id: collectionID,
                    name: "Reading",
                    dictionaryName: "ODE",
                    deckDescription: "desc",
                    createdAt: 10,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt
                )
            ],
            words: [
                SyncWordRecord(
                    id: wordID,
                    collectionId: collectionID,
                    normalizedWord: "apple",
                    displayWord: "Apple",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: nil,
                        lookupRefreshedAt: nil,
                        payloadUpdatedAt: deletedAt,
                        audioRef: nil,
                        aiArtifactsJSON: nil
                    )
                )
            ]
        )

        let merge = SyncMerger.merge(local: local, remote: nil, now: now)

        XCTAssertTrue(merge.mergedManifest.collections.isEmpty)
        XCTAssertTrue(merge.mergedManifest.words.isEmpty)
        XCTAssertEqual(merge.localCollectionTombstonesToPurge, Set([collectionID]))
        XCTAssertEqual(merge.localWordTombstonesToPurge, Set([wordID]))
    }

    func testMergePrunesExpiredTombstonesAgainstEmptyRemoteManifest() {
        let now: TimeInterval = 200 * 24 * 60 * 60
        let deletedAt = now - (90 * 24 * 60 * 60) - 1
        let collectionID = "col-1"
        let wordID = "word-1"
        let local = SyncManifest(
            deviceId: "local",
            collections: [
                SyncCollectionRecord(
                    id: collectionID,
                    name: "Reading",
                    dictionaryName: "ODE",
                    deckDescription: "desc",
                    createdAt: 10,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt
                )
            ],
            words: [
                SyncWordRecord(
                    id: wordID,
                    collectionId: collectionID,
                    normalizedWord: "apple",
                    displayWord: "Apple",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: nil,
                        lookupRefreshedAt: nil,
                        payloadUpdatedAt: deletedAt,
                        audioRef: nil,
                        aiArtifactsJSON: nil
                    )
                )
            ]
        )
        let remote = SyncManifest(deviceId: "remote", collections: [], words: [])

        let merge = SyncMerger.merge(local: local, remote: remote, now: now)

        XCTAssertTrue(merge.mergedManifest.collections.isEmpty)
        XCTAssertTrue(merge.mergedManifest.words.isEmpty)
        XCTAssertEqual(merge.localCollectionTombstonesToPurge, Set([collectionID]))
        XCTAssertEqual(merge.localWordTombstonesToPurge, Set([wordID]))
    }

    func testMergeKeepsExpiredTombstonesWhenActiveCounterpartStillExists() {
        let now: TimeInterval = 200 * 24 * 60 * 60
        let deletedAt = now - (90 * 24 * 60 * 60) - 1
        let collectionID = "col-1"
        let wordID = "word-1"
        let local = SyncManifest(
            deviceId: "local",
            collections: [
                SyncCollectionRecord(
                    id: collectionID,
                    name: "Reading",
                    dictionaryName: "ODE",
                    deckDescription: "desc",
                    createdAt: 10,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt
                )
            ],
            words: [
                SyncWordRecord(
                    id: wordID,
                    collectionId: collectionID,
                    normalizedWord: "apple",
                    displayWord: "Apple",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: deletedAt,
                    deletedAt: deletedAt,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: nil,
                        lookupRefreshedAt: nil,
                        payloadUpdatedAt: deletedAt,
                        audioRef: nil,
                        aiArtifactsJSON: nil
                    )
                )
            ]
        )
        let remote = SyncManifest(
            deviceId: "remote",
            collections: [
                SyncCollectionRecord(
                    id: collectionID,
                    name: "Reading Remote",
                    dictionaryName: "ODE",
                    deckDescription: "desc",
                    createdAt: 10,
                    updatedAt: deletedAt - 10,
                    deletedAt: nil
                )
            ],
            words: [
                SyncWordRecord(
                    id: wordID,
                    collectionId: collectionID,
                    normalizedWord: "apple",
                    displayWord: "Apple Remote",
                    sourceForm: nil,
                    inflectionKind: nil,
                    expectedPartOfSpeech: nil,
                    createdAt: 10,
                    updatedAt: deletedAt - 10,
                    deletedAt: nil,
                    payload: SyncWordPayloadRecord(
                        lookupStateBase64: nil,
                        lookupRefreshedAt: nil,
                        payloadUpdatedAt: deletedAt - 10,
                        audioRef: nil,
                        aiArtifactsJSON: nil
                    )
                )
            ]
        )

        let merge = SyncMerger.merge(local: local, remote: remote, now: now)

        XCTAssertEqual(merge.mergedManifest.collections.first?.deletedAt, deletedAt)
        XCTAssertEqual(merge.mergedManifest.words.first?.deletedAt, deletedAt)
        XCTAssertTrue(merge.localCollectionTombstonesToPurge.isEmpty)
        XCTAssertTrue(merge.localWordTombstonesToPurge.isEmpty)
    }
}
