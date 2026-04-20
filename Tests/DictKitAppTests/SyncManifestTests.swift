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
                    ankiDeckName: "Reading",
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
        XCTAssertEqual(upgraded.version, 1)
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
}
