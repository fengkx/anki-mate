import DictKit
import Foundation
import XCTest
@testable import DictKitApp

final class WordListStoreTests: XCTestCase {
    func testInitCreatesDefaultCollection() throws {
        let store = try makeStore()

        let collections = try store.loadCollections()

        XCTAssertEqual(collections.count, 1)
        XCTAssertEqual(collections.only?.name, "Default")
        XCTAssertEqual(collections.only?.ankiDeckName, "Default")
    }

    func testUpsertWordRoundTripsLookupResultAndAudioWithinCollection() throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: Data([0x01, 0x02, 0x03]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 30)
        )

        let result = try store.upsertWord(record, into: collection.id)

        XCTAssertTrue(result.insertedWord)
        XCTAssertTrue(result.insertedAssociation)
        XCTAssertEqual(try store.loadWords(in: collection.id).only, record)
    }

    func testAddingExistingWordToAnotherCollectionReusesGlobalWordRecord() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let secondaryCollection = try store.createCollection(name: "Study Set", deckName: nil)
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: Data([0x05]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 30)
        )

        _ = try store.upsertWord(record, into: defaultCollection.id)
        let result = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "apple",
                normalizedWord: WordListStore.normalizedWord(for: "apple"),
                lookupState: .pending,
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 40),
                updatedAt: Date(timeIntervalSince1970: 40),
                lastRefreshedAt: nil
            ),
            into: secondaryCollection.id
        )

        XCTAssertFalse(result.insertedWord)
        XCTAssertTrue(result.insertedAssociation)
        XCTAssertEqual(result.record.id, record.id)
        XCTAssertEqual(try store.loadWords(in: defaultCollection.id).only?.id, record.id)
        XCTAssertEqual(try store.loadWords(in: secondaryCollection.id).only?.id, record.id)
    }

    func testRemoveWordFromOneCollectionKeepsItInOthers() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let secondaryCollection = try store.createCollection(name: "Study Set", deckName: nil)
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(record, into: defaultCollection.id)
        _ = try store.upsertWord(record, into: secondaryCollection.id)

        try store.removeWord(id: record.id, from: defaultCollection.id)

        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: secondaryCollection.id).only?.id, record.id)
        XCTAssertEqual(try store.loadAllWords().only?.id, record.id)
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

    private static func makeLookupResult(query: String, definition: String) -> LookupResult {
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
                                    examples: [],
                                    registers: [],
                                    countability: .countable
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
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
