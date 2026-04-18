import DictKit
import Foundation
import SQLite3
import XCTest
@testable import DictKitApp

final class WordListStoreTests: XCTestCase {
    func testInitCreatesDefaultCollection() throws {
        let store = try makeStore()

        let collections = try store.loadCollections()

        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.only?.name, "Default")
        XCTAssertEqual(collections.only?.dictionaryName, "")
        XCTAssertEqual(collections.only?.ankiDeckName, "Default")
        XCTAssertEqual(collections.only?.ankiDeckDescription, "")
    }

    func testInitResetsPreRedesignSchema() throws {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let databaseURL = baseURL.appendingPathComponent("word-list.sqlite3")
        try writePreRedesignFixture(to: databaseURL)

        let store = try WordListStore(databaseURL: databaseURL)

        let collections = try store.loadCollections()

        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.only?.name, "Default")
        XCTAssertEqual(collections.only?.dictionaryName, "")
        XCTAssertTrue(try store.loadAllWords().isEmpty)
        XCTAssertEqual(try readUserVersion(at: databaseURL), 1)
        XCTAssertEqual(try readApplicationID(at: databaseURL), 0x414D5632)
        XCTAssertEqual(try legacyBackupURLs(in: baseURL).count, 1)
    }

    func testInitCreatesPayloadTableForNewGeneration() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])),
            audioData: Data([0x01, 0x02, 0x03]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 30)
        )

        _ = try store.upsertWord(record, into: collection.id)

        try store.withDatabase { db in
            XCTAssertTrue(try WordListStore.tableExists("word_payloads", db: db))
            for indexName in Self.requiredIndexNames {
                XCTAssertTrue(try WordListStore.indexExists(indexName, db: db), "Missing index: \(indexName)")
            }

            let sql = "SELECT audio_sha256, ai_artifacts_json, payload_updated_at FROM word_payloads WHERE word_id = ?"
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, record.id.uuidString, -1, testTransientDestructor)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            XCTAssertEqual(String(cString: sqlite3_column_text(stmt, 0)), WordListStore.computeAudioHash(Data([0x01, 0x02, 0x03])))
            XCTAssertEqual(Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)), record.updatedAt)
        }
    }

    func testCreateCollectionStoresDictionaryName() throws {
        let store = try makeStore()

        let collection = try store.createCollection(
            name: "Reading",
            exportSettings: CollectionExportSettings(
                deckName: "Reading",
                deckDescription: "Reading vocabulary"
            ),
            dictionaryName: "Oxford Dictionary of English"
        )

        XCTAssertEqual(collection.name, "Reading")
        XCTAssertEqual(collection.dictionaryName, "Oxford Dictionary of English")
        XCTAssertEqual(collection.ankiDeckName, "Reading")
        XCTAssertEqual(collection.ankiDeckDescription, "Reading vocabulary")
    }

    func testHasChangesAfterLastSyncTreatsFreshCollectionStateAsPending() throws {
        let store = try makeStore()

        XCTAssertTrue(try store.hasChangesAfterLastSync())
    }

    func testCreateCollectionUsesCollectionNameFallbackForBlankDeckName() throws {
        let store = try makeStore()

        let collection = try store.createCollection(
            name: "Study Set",
            exportSettings: CollectionExportSettings(
                deckName: "   ",
                deckDescription: "  Custom description  "
            ),
            dictionaryName: ""
        )

        XCTAssertEqual(collection.name, "Study Set")
        XCTAssertEqual(collection.ankiDeckName, "Study Set")
        XCTAssertEqual(collection.ankiDeckDescription, "Custom description")
    }

    func testCreateCollectionAllowsReusingSoftDeletedName() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let collection = try store.createCollection(
            name: "Reading",
            exportSettings: CollectionExportSettings(deckName: "Reading", deckDescription: ""),
            dictionaryName: ""
        )

        try store.deleteCollection(id: collection.id)

        let recreated = try store.createCollection(
            name: "Reading",
            exportSettings: CollectionExportSettings(deckName: "Reading", deckDescription: "Updated"),
            dictionaryName: "Oxford"
        )

        let collections = try store.loadCollections()
        XCTAssertEqual(collections.map(\.id).sorted { $0.uuidString < $1.uuidString }, [defaultCollection.id, recreated.id].sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(recreated.name, "Reading")
        XCTAssertEqual(recreated.dictionaryName, "Oxford")
    }

    func testRenameCollectionUpdatesDictionaryAndExportSettingsIndependently() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)

        let renamed = try store.renameCollection(
            id: collection.id,
            name: "Reading",
            exportSettings: CollectionExportSettings(
                deckName: "English::Reading",
                deckDescription: "Review reading vocabulary"
            ),
            dictionaryName: "Oxford Dictionary of English"
        )

        XCTAssertEqual(renamed.name, "Reading")
        XCTAssertEqual(renamed.dictionaryName, "Oxford Dictionary of English")
        XCTAssertEqual(renamed.ankiDeckName, "English::Reading")
        XCTAssertEqual(renamed.ankiDeckDescription, "Review reading vocabulary")
    }

    func testUpsertWordRoundTripsLookupResultAndAudioWithinCollection() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])),
            audioData: Data([0x01, 0x02, 0x03]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 30)
        )

        let result = try store.upsertWord(record, into: collection.id)

        XCTAssertTrue(result.insertedWord)
        XCTAssertEqual(try store.loadWords(in: collection.id).only, record)
    }

    func testUpsertDuplicateWordRejectsInsideSameCollection() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .pending,
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            lastRefreshedAt: nil
        )

        _ = try store.upsertWord(record, into: collection.id)

        XCTAssertThrowsError(
            try store.upsertWord(
                PersistedWordRecord(
                    id: UUID(),
                    displayWord: "apple",
                    normalizedWord: WordListStore.normalizedWord(for: "apple"),
                    lookupState: .pending,
                    audioData: nil,
                    createdAt: Date(timeIntervalSince1970: 20),
                    updatedAt: Date(timeIntervalSince1970: 20),
                    lastRefreshedAt: nil
                ),
                into: collection.id
            )
        )
    }

    func testSameWordCanExistInTwoCollectionsIndependently() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let secondaryCollection = try store.createCollection(
            name: "Study Set",
            exportSettings: CollectionExportSettings(deckName: "Study Set", deckDescription: ""),
            dictionaryName: ""
        )
        let record1 = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
            audioData: Data([0x05]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 30)
        )
        let record2 = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "company", examples: [])),
            audioData: Data([0x09]),
            createdAt: Date(timeIntervalSince1970: 40),
            updatedAt: Date(timeIntervalSince1970: 50),
            lastRefreshedAt: Date(timeIntervalSince1970: 60)
        )

        _ = try store.upsertWord(record1, into: defaultCollection.id)
        _ = try store.upsertWord(record2, into: secondaryCollection.id)

        let defaultWord = try XCTUnwrap(try store.loadWords(in: defaultCollection.id).only)
        let secondaryWord = try XCTUnwrap(try store.loadWords(in: secondaryCollection.id).only)

        XCTAssertNotEqual(defaultWord.id, secondaryWord.id)
        XCTAssertEqual(defaultWord.lookupState, record1.lookupState)
        XCTAssertEqual(secondaryWord.lookupState, record2.lookupState)
    }

    func testRemoveWordDeletesOnlyCurrentCollectionOwnedRow() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let secondaryCollection = try store.createCollection(
            name: "Study Set",
            exportSettings: CollectionExportSettings(deckName: "Study Set", deckDescription: ""),
            dictionaryName: ""
        )
        let record1 = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
            audioData: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        let record2 = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "company", examples: [])),
            audioData: Data([0x02]),
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(record1, into: defaultCollection.id)
        _ = try store.upsertWord(record2, into: secondaryCollection.id)

        try store.removeWord(id: record1.id, from: defaultCollection.id)

        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: secondaryCollection.id).only?.id, record2.id)
        XCTAssertEqual(try store.loadAllWords().only?.id, record2.id)
    }

    func testUpsertWordAllowsReusingSoftDeletedNormalizedWord() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let original = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .pending,
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            lastRefreshedAt: nil
        )
        let replacement = PersistedWordRecord(
            id: UUID(),
            displayWord: "apple",
            normalizedWord: WordListStore.normalizedWord(for: "apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "company", examples: [])),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 30),
            lastRefreshedAt: nil
        )

        _ = try store.upsertWord(original, into: collection.id)
        try store.removeWord(id: original.id, from: collection.id)

        let result = try store.upsertWord(replacement, into: collection.id)

        XCTAssertTrue(result.insertedWord)
        XCTAssertEqual(try store.loadWords(in: collection.id).only?.id, replacement.id)
    }

    func testHasChangesAfterLastSyncTracksPayloadUpdates() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let original = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .pending,
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            lastRefreshedAt: nil
        )

        _ = try store.upsertWord(original, into: collection.id)
        try store.setSyncMetadata("15", forKey: "last_sync_timestamp")

        let updated = PersistedWordRecord(
            id: original.id,
            displayWord: original.displayWord,
            normalizedWord: original.normalizedWord,
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
            audioData: Data([0xAB]),
            createdAt: original.createdAt,
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 20)
        )
        try store.saveWord(updated)

        XCTAssertTrue(try store.hasChangesAfterLastSync())
    }

    func testDeleteLastCollectionIsRejected() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)

        XCTAssertThrowsError(try store.deleteCollection(id: collection.id))
    }

    private func makeStore() throws -> WordListStore {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return try WordListStore(databaseURL: baseURL.appendingPathComponent("word-list.sqlite3"))
    }

    private func writePreRedesignFixture(to databaseURL: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        guard let db else {
            XCTFail("Failed to open sqlite database")
            return
        }
        defer { sqlite3_close(db) }

        try exec(
            db,
            sql: """
            PRAGMA user_version = 4;
            CREATE TABLE words (
              id TEXT PRIMARY KEY,
              normalized_word TEXT NOT NULL UNIQUE,
              display_word TEXT NOT NULL,
              lookup_state_json BLOB,
              audio_data BLOB,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              last_refreshed_at REAL
            );
            CREATE TABLE collections (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL COLLATE NOCASE UNIQUE,
              anki_deck_name TEXT NOT NULL,
              deck_description TEXT NOT NULL,
              package_filename_stem TEXT NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL
            );
            CREATE TABLE collection_words (
              collection_id TEXT NOT NULL,
              word_id TEXT NOT NULL,
              created_at REAL NOT NULL,
              PRIMARY KEY (collection_id, word_id),
              FOREIGN KEY (collection_id) REFERENCES collections(id) ON DELETE CASCADE,
              FOREIGN KEY (word_id) REFERENCES words(id) ON DELETE CASCADE
            );
            """
        )

        let collectionID = UUID()
        let wordID = UUID()
        let lookupData = try JSONEncoder().encode(
            PersistedLookupState.loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"]))
        )
        let lookupJSONString = (String(data: lookupData, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "'", with: "''")

        try exec(
            db,
            sql: """
            INSERT INTO collections (id, name, anki_deck_name, deck_description, package_filename_stem, created_at, updated_at)
            VALUES ('\(collectionID.uuidString)', 'Legacy', 'Legacy', '', 'Legacy', 1, 1);
            INSERT INTO words (id, normalized_word, display_word, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at)
            VALUES ('\(wordID.uuidString)', 'apple', 'Apple', '\(lookupJSONString)', NULL, 1, 1, NULL);
            INSERT INTO collection_words (collection_id, word_id, created_at)
            VALUES ('\(collectionID.uuidString)', '\(wordID.uuidString)', 1);
            """
        )
    }

    private func exec(_ db: OpaquePointer, sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let message = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            XCTFail("sqlite exec failed: \(message)")
            throw NSError(domain: "WordListStoreTests", code: 1)
        }
    }

    private func readUserVersion(at url: URL) throws -> Int {
        try readPragmaInt(at: url, pragma: "user_version")
    }

    private func readApplicationID(at url: URL) throws -> Int {
        try readPragmaInt(at: url, pragma: "application_id")
    }

    private func readPragmaInt(at url: URL, pragma: String) throws -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        guard let db else {
            XCTFail("Failed to open sqlite database")
            return 0
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA \(pragma);", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func legacyBackupURLs(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("word-list.legacy-") }
    }

    private static func makeLookupResult(query: String, definition: String, examples: [String]) -> LookupResult {
        LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: query,
                    pronunciations: [
                        Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)
                    ],
                    lexicalEntries: [
                        LexicalEntry(
                            partOfSpeech: .noun,
                            partOfSpeechLabel: "noun",
                            displayIndex: 0,
                            pronunciations: [
                                Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)
                            ],
                            senses: [
                                Sense(
                                    number: 1,
                                    semanticHint: nil,
                                    definition: definition,
                                    examples: examples,
                                    registers: [],
                                    countability: nil
                                )
                            ],
                            grammar: [],
                            inflections: []
                        )
                    ],
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }

    private static let requiredIndexNames = [
        "collections_name_active_idx",
        "words_collection_normalized_active_idx",
        "collections_created_at_idx",
        "collections_active_created_idx",
        "collections_updated_at_idx",
        "words_created_at_idx",
        "words_collection_active_created_idx",
        "words_active_created_idx",
        "words_updated_at_idx",
        "word_payloads_payload_updated_at_idx"
    ]
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private let testTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
