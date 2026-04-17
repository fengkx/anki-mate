import DictKit
import DictKitSystemDictionary
import Foundation
import Combine
import XCTest
@testable import DictKitApp

@MainActor
final class WordListViewModelTests: XCTestCase {
    func testInitRestoresDefaultCollectionAndScopedWords() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(
            name: "Other",
            exportSettings: CollectionExportSettings(deckName: "Other", deckDescription: ""),
            dictionaryName: ""
        )
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Banana",
                normalizedWord: WordListStore.normalizedWord(for: "Banana"),
                lookupState: .loaded(Self.makeLookupResult(query: "banana", definition: "fruit", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 20),
                updatedAt: Date(timeIntervalSince1970: 20),
                lastRefreshedAt: nil
            ),
            into: otherCollection.id
        )

        let viewModel = try makeViewModel(store: store)

        XCTAssertEqual(viewModel.currentCollection?.id, defaultCollection.id)
        XCTAssertEqual(viewModel.words.map(\.word), ["Apple"])
    }

    func testSwitchingCollectionFiltersWords() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(
            name: "Other",
            exportSettings: CollectionExportSettings(deckName: "Other", deckDescription: ""),
            dictionaryName: ""
        )
        _ = try store.upsertWord(PersistedWordRecord(item: WordItem(word: "Apple")), into: defaultCollection.id)
        _ = try store.upsertWord(PersistedWordRecord(item: WordItem(word: "Banana")), into: otherCollection.id)

        let viewModel = try makeViewModel(store: store)

        XCTAssertEqual(viewModel.words.map(\.word), ["Apple"])

        viewModel.selectCollection(id: otherCollection.id)

        XCTAssertEqual(viewModel.words.map(\.word), ["Banana"])
    }

    func testCreateCollectionPersistsCustomDictionaryAndExportSettings() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)

        let created = viewModel.createCollection(
            using: CollectionEditorFormData(
                collectionName: "Reading",
                deckDescription: "Reading vocabulary",
                dictionaryName: "Oxford Dictionary of English"
            )
        )

        XCTAssertTrue(created)
        XCTAssertEqual(viewModel.currentCollection?.name, "Reading")
        XCTAssertEqual(viewModel.currentCollection?.dictionaryName, "Oxford Dictionary of English")
        XCTAssertEqual(viewModel.currentCollection?.ankiDeckName, "Reading")
        XCTAssertEqual(viewModel.currentCollection?.ankiDeckDescription, "Reading vocabulary")
    }

    func testRenameCurrentCollectionPersistsDictionaryAndDeckDescription() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)

        let renamed = viewModel.renameCurrentCollection(
            using: CollectionEditorFormData(
                collectionName: "Reading",
                deckDescription: "Review reading vocabulary",
                dictionaryName: "Oxford Dictionary of English"
            )
        )

        XCTAssertTrue(renamed)
        XCTAssertEqual(viewModel.currentCollection?.name, "Reading")
        XCTAssertEqual(viewModel.currentCollection?.dictionaryName, "Oxford Dictionary of English")
        XCTAssertEqual(viewModel.currentCollection?.ankiDeckDescription, "Review reading vocabulary")
    }

    func testDefaultExportRequestUsesCurrentCollectionName() throws {
        let store = try makeStore()
        let otherCollection = try store.createCollection(
            name: "Other",
            exportSettings: CollectionExportSettings(deckName: "Other Deck", deckDescription: "Notes"),
            dictionaryName: "Oxford Dictionary of English"
        )
        let viewModel = try makeViewModel(store: store)

        viewModel.selectCollection(id: otherCollection.id)
        let request = try XCTUnwrap(viewModel.defaultExportRequest())

        XCTAssertEqual(request.collectionID, otherCollection.id)
        XCTAssertEqual(request.deckDescription, "Notes")
    }

    func testInitExposesStoreInitializationError() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(
            store: store,
            storeErrorMessage: "Storage initialization failed."
        )

        XCTAssertEqual(viewModel.storeErrorMessage, "Storage initialization failed.")
    }

    func testDeleteSelectedWordRemovesOnlyCurrentCollectionOwnedRow() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(
            name: "Other",
            exportSettings: CollectionExportSettings(deckName: "Other", deckDescription: ""),
            dictionaryName: ""
        )

        _ = try store.upsertWord(PersistedWordRecord(item: WordItem(word: "Apple")), into: defaultCollection.id)
        _ = try store.upsertWord(PersistedWordRecord(item: WordItem(word: "Apple")), into: otherCollection.id)

        let viewModel = try makeViewModel(store: store)
        viewModel.selectedWordID = try XCTUnwrap(viewModel.words.only?.id)

        viewModel.deleteSelectedWord()

        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: otherCollection.id).map(\.word), ["Apple"])
    }

    func testReloadFromStoreReflectsExternalChangesImmediately() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let viewModel = try makeViewModel(store: store)

        XCTAssertTrue(viewModel.words.isEmpty)

        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )

        viewModel.reloadFromStore()

        XCTAssertEqual(viewModel.words.map(\.word), ["Apple"])
    }

    func testWordItemChangesTriggerViewModelUpdatesForDerivedUIState() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .pending,
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )

        let viewModel = try makeViewModel(store: store)
        let item = try XCTUnwrap(viewModel.words.only)
        let changed = expectation(description: "ViewModel forwards nested word changes")
        var cancellables = Set<AnyCancellable>()

        viewModel.objectWillChange
            .sink { _ in changed.fulfill() }
            .store(in: &cancellables)

        item.lookupState = .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: []))

        wait(for: [changed], timeout: 1.0)
        XCTAssertEqual(viewModel.readyCount, 1)
        XCTAssertEqual(viewModel.wordsColumnSummary, "1 of 1 ready")
        XCTAssertEqual(viewModel.exportableWordCount(for: defaultCollection.id), 1)
    }

    func testAIContentPersistsAcrossReload() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )

        let viewModel = try makeViewModel(store: store)
        let item = try XCTUnwrap(viewModel.words.only)

        viewModel.saveAISuggestedExampleSentences(["Suggested example."], for: item)
        viewModel.saveAIAcceptedExampleSentences(["An apple a day keeps the doctor away."], for: item)
        viewModel.saveAISuggestedDefinitionNote("Suggested note.", for: item)
        viewModel.saveAIAcceptedDefinitionNote("A learner-friendly definition.", for: item)
        viewModel.reloadFromStore()

        let reloaded = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(reloaded.aiSuggestedExampleSentences, ["Suggested example."])
        XCTAssertEqual(reloaded.aiAcceptedExampleSentences, ["An apple a day keeps the doctor away."])
        XCTAssertEqual(reloaded.aiSuggestedDefinitionNote, "Suggested note.")
        XCTAssertEqual(reloaded.aiAcceptedDefinitionNote, "A learner-friendly definition.")
    }

    func testAddWordUsesPublicResultWhenExamplesExist() async throws {
        let store = try makeStore()
        let publicResult = Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])
        let privateResult = Self.makeLookupResult(query: "apple", definition: "private fruit", examples: ["Private example"], usedSource: .privateHTML)
        let spy = LookupSpy(results: [
            (.publicAPI, publicResult),
            (.privateHTML(dictionaryName: "Oxford Dictionary of English"), privateResult),
        ])
        let viewModel = try makeViewModel(store: store, rawLookup: spy.lookup)

        viewModel.addWord("apple")
        await viewModel.waitForIdle()

        let recordedSources = await spy.recordedSources()
        XCTAssertEqual(recordedSources, [.publicAPI])
        XCTAssertEqual(viewModel.words.only?.lookupResult, publicResult)
    }

    func testAddWordFallsBackToPrivateDictionaryWhenPublicHasNoExamples() async throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        _ = try store.renameCollection(
            id: defaultCollection.id,
            name: defaultCollection.name,
            exportSettings: defaultCollection.exportSettings,
            dictionaryName: "Oxford Dictionary of English"
        )

        let publicResult = Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])
        let privateResult = Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"], usedSource: .privateHTML)
        let spy = LookupSpy(results: [
            (.publicAPI, publicResult),
            (.privateHTML(dictionaryName: "Oxford Dictionary of English"), privateResult),
        ])
        let viewModel = try makeViewModel(store: store, rawLookup: spy.lookup)

        viewModel.addWord("apple")
        await viewModel.waitForIdle()

        let recordedSources = await spy.recordedSources()
        XCTAssertEqual(recordedSources, [.publicAPI, .privateHTML(dictionaryName: "Oxford Dictionary of English")])
        XCTAssertEqual(viewModel.words.only?.lookupResult, privateResult)
    }

    func testAddWordFallsBackToDefaultPrivateDictionaryWhenCollectionDictionaryIsAutomatic() async throws {
        let store = try makeStore()
        let privateResult = Self.makeLookupResult(
            query: "lemmatization",
            definition: "analysis of word lemmas",
            examples: ["Lemmatization reduces inflected words to their base form."],
            usedSource: .privateHTML
        )
        let spy = LookupSpy(results: [
            (.privateHTML(dictionaryName: SystemDictionaryClient.defaultDictionaryName), privateResult)
        ])
        let viewModel = try makeViewModel(store: store, rawLookup: spy.lookup)

        viewModel.addWord("lemmatization")
        await viewModel.waitForIdle()

        let recordedSources = await spy.recordedSources()
        XCTAssertEqual(
            recordedSources,
            [.publicAPI, .privateHTML(dictionaryName: SystemDictionaryClient.defaultDictionaryName)]
        )
        XCTAssertEqual(viewModel.words.only?.lookupResult, privateResult)
    }

    func testAddInflectedWordStoresLemmaAndSourceForm() async throws {
        let store = try makeStore()
        let spy = LookupSpy(results: [
            (.publicAPI, Self.makeLookupResult(
                query: "flock",
                definition: "to gather",
                examples: ["students flocked downtown"],
                headword: "flock",
                partOfSpeech: .verb,
                partOfSpeechLabel: "verb",
                inflections: ["flocked"]
            ))
        ])
        let viewModel = try makeViewModel(store: store, rawLookup: spy.lookup)

        viewModel.addWord("flocked")
        await viewModel.waitForIdle()

        XCTAssertEqual(viewModel.words.only?.word, "flock")
        XCTAssertEqual(viewModel.words.only?.sourceForm, "flocked")
        XCTAssertEqual(viewModel.words.only?.inflectionKind, .pastOrPastParticiple)
        XCTAssertEqual(viewModel.words.only?.expectedPartOfSpeech, .verb)
    }

    func testResolvedLemmaMergesWithExistingWordInSameCollection() async throws {
        let store = try makeStore()
        let spy = LookupSpy(results: [
            (.publicAPI, Self.makeLookupResult(
                query: "flock",
                definition: "to gather",
                examples: ["students flocked downtown"],
                headword: "flock",
                partOfSpeech: .verb,
                partOfSpeechLabel: "verb",
                inflections: ["flocked"]
            ))
        ])
        let viewModel = try makeViewModel(store: store, rawLookup: spy.lookup)

        viewModel.addWord("flock")
        await viewModel.waitForIdle()
        viewModel.addWord("flocked")
        await viewModel.waitForIdle()

        XCTAssertEqual(viewModel.words.count, 1)
        XCTAssertEqual(viewModel.words.only?.word, "flock")
    }

    func testRetryLookupUsesUpdatedCollectionDictionary() async throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        _ = try store.renameCollection(
            id: defaultCollection.id,
            name: defaultCollection.name,
            exportSettings: defaultCollection.exportSettings,
            dictionaryName: "Oxford Dictionary of English"
        )
        let spy = LookupSpy(results: [
            (.publicAPI, Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
            (.privateHTML(dictionaryName: "Oxford Dictionary of English"), Self.makeLookupResult(query: "apple", definition: "first private", examples: ["First private"], usedSource: .privateHTML)),
            (.privateHTML(dictionaryName: "牛津英汉汉英词典"), Self.makeLookupResult(query: "apple", definition: "second private", examples: ["Second private"], usedSource: .privateHTML)),
        ])
        let viewModel = try makeViewModel(store: store, rawLookup: spy.lookup)

        viewModel.addWord("apple")
        await viewModel.waitForIdle()

        let renamed = viewModel.renameCurrentCollection(
            using: CollectionEditorFormData(
                collectionName: "Default",
                deckDescription: "",
                dictionaryName: "牛津英汉汉英词典"
            )
        )
        XCTAssertTrue(renamed)

        let item = try XCTUnwrap(viewModel.words.only)
        viewModel.retryLookup(item)
        await viewModel.waitForIdle()

        let recordedSources = await spy.recordedSources()
        XCTAssertEqual(
            recordedSources,
            [
                .publicAPI,
                .privateHTML(dictionaryName: "Oxford Dictionary of English"),
                .publicAPI,
                .privateHTML(dictionaryName: "牛津英汉汉英词典"),
            ]
        )
        XCTAssertEqual(viewModel.words.only?.lookupResult?.entries.first?.lexicalEntries.first?.senses.first?.examples, ["Second private"])
    }

    private func makeStore() throws -> WordListStore {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return try WordListStore(databaseURL: baseURL.appendingPathComponent("word-list.sqlite3"))
    }

    private func makeViewModel(store: any WordListStoring) throws -> WordListViewModel {
        try makeViewModel(store: store, storeErrorMessage: nil) { _, _ in
            Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])
        }
    }

    private func makeViewModel(
        store: any WordListStoring,
        storeErrorMessage: String?
    ) throws -> WordListViewModel {
        try makeViewModel(store: store, storeErrorMessage: storeErrorMessage) { _, _ in
            Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])
        }
    }

    private func makeViewModel(
        store: any WordListStoring,
        storeErrorMessage: String? = nil,
        rawLookup: @escaping @Sendable (String, DictionaryLookupSource) async throws -> LookupResult
    ) throws -> WordListViewModel {
        try WordListViewModel(
            store: store,
            storeErrorMessage: storeErrorMessage,
            lookup: rawLookup,
            speak: { _ in },
            synthesize: { _ in Data() }
        )
    }

    nonisolated private static func makeLookupResult(
        query: String,
        definition: String,
        examples: [String],
        usedSource: LookupSourceKind = .publicAPI,
        headword: String? = nil,
        partOfSpeech: PartOfSpeech = .noun,
        partOfSpeechLabel: String = "noun",
        inflections: [String] = []
    ) -> LookupResult {
        LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: headword ?? query,
                    pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)],
                    lexicalEntries: [
                        LexicalEntry(
                            partOfSpeech: partOfSpeech,
                            partOfSpeechLabel: partOfSpeechLabel,
                            displayIndex: 0,
                            pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)],
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
                            inflections: inflections
                        )
                    ],
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: usedSource, warnings: []),
            source: nil
        )
    }
}

private actor LookupSpy {
    private let results: [(DictionaryLookupSource, LookupResult)]
    private var sources: [DictionaryLookupSource] = []

    init(results: [(DictionaryLookupSource, LookupResult)]) {
        self.results = results
    }

    func lookup(_ term: String, source: DictionaryLookupSource) async throws -> LookupResult {
        sources.append(source)
        if let result = results.first(where: { $0.0 == source })?.1 {
            return result
        }
        throw LookupError.notFound
    }

    func recordedSources() -> [DictionaryLookupSource] {
        sources
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
