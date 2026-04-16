import DictKit
import Foundation
import XCTest
@testable import DictKitApp

final class WordListViewModelTests: XCTestCase {
    @MainActor
    func testInitRestoresDefaultCollectionAndScopedWords() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: Data([0xAA, 0xBB]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: Date(timeIntervalSince1970: 30)
        )
        let banana = PersistedWordRecord(
            id: UUID(),
            displayWord: "Banana",
            normalizedWord: WordListStore.normalizedWord(for: "Banana"),
            lookupState: .pending,
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 21),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(banana, into: otherCollection.id)

        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fresh") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        XCTAssertEqual(viewModel.collections.map(\.name), ["Default", "Other"])
        XCTAssertEqual(viewModel.currentCollection?.id, defaultCollection.id)
        XCTAssertEqual(viewModel.words.map(\.word), ["Apple"])
    }

    @MainActor
    func testAddWordAddsToCurrentCollectionOnly() throws {
        let store = try makeStore()
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: otherCollection.id)
        viewModel.addWord("Apple")

        XCTAssertEqual(viewModel.words.map(\.word), ["Apple"])
        XCTAssertTrue(try store.loadWords(in: try XCTUnwrap(viewModel.collections.first(where: { $0.name == "Default" })).id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: otherCollection.id).map(\.word), ["Apple"])
    }

    @MainActor
    func testSwitchingCollectionFiltersWords() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
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
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Banana",
                normalizedWord: WordListStore.normalizedWord(for: "Banana"),
                lookupState: .pending,
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastRefreshedAt: nil
            ),
            into: otherCollection.id
        )
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        XCTAssertEqual(viewModel.words.map(\.word), ["Apple"])
        viewModel.selectCollection(id: otherCollection.id)
        XCTAssertEqual(viewModel.words.map(\.word), ["Banana"])
    }

    @MainActor
    func testSwitchingCollectionClearsSelectedWordWhenWordIsMissing() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10),
            lastRefreshedAt: nil
        )
        let banana = PersistedWordRecord(
            id: UUID(),
            displayWord: "Banana",
            normalizedWord: WordListStore.normalizedWord(for: "Banana"),
            lookupState: .loaded(Self.makeLookupResult(query: "banana", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 11),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(banana, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectedWordID = apple.id
        viewModel.selectCollection(id: otherCollection.id)

        XCTAssertNil(viewModel.selectedWordID)
        XCTAssertEqual(viewModel.words.map(\.word), ["Banana"])
    }

    @MainActor
    func testCreateCollectionDuplicateNameSetsVisibleError() throws {
        let store = try makeStore()
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        let created = viewModel.createCollection(named: "Default")

        XCTAssertFalse(created)
        XCTAssertEqual(viewModel.collectionEditorErrorMessage, "Duplicate collection: Default")
    }

    @MainActor
    func testExportableWordCountReflectsReadyWordsPerCollection() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
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
                lookupState: .pending,
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Cherry",
                normalizedWord: WordListStore.normalizedWord(for: "Cherry"),
                lookupState: .loaded(Self.makeLookupResult(query: "cherry", definition: "fruit")),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 12),
                updatedAt: Date(timeIntervalSince1970: 12),
                lastRefreshedAt: nil
            ),
            into: otherCollection.id
        )

        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        XCTAssertEqual(viewModel.exportableWordCount(for: defaultCollection.id), 1)
        XCTAssertEqual(viewModel.exportableWordCount(for: otherCollection.id), 1)
    }

    @MainActor
    func testWordsColumnHeaderUsesCurrentCollectionNameAndCounts() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
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
                lookupState: .pending,
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 11),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        XCTAssertEqual(viewModel.wordsColumnTitle, "Default")
        XCTAssertEqual(viewModel.wordsColumnSummary, "1 of 2 ready")
    }

    @MainActor
    func testDeleteSelectedWordRemovesOnlyCurrentCollectionMembership() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )
        viewModel.selectedWordID = apple.id

        viewModel.deleteSelectedWord()

        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.id, apple.id)
        XCTAssertEqual(pendingWordDeletion.wordID, apple.id)
        XCTAssertEqual(pendingWordDeletion.word, "Apple")
        XCTAssertEqual(pendingWordDeletion.currentCollectionName, "Default")
        XCTAssertEqual(pendingWordDeletion.otherCollectionNames, ["Other"])
        XCTAssertEqual(viewModel.words.map(\.id), [apple.id])
        XCTAssertEqual(viewModel.selectedWordID, apple.id)
        XCTAssertEqual(try store.loadWords(in: otherCollection.id).only?.id, apple.id)
    }

    @MainActor
    func testRemoveWordsRequestsPendingDeletionForFirstOffset() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        let banana = PersistedWordRecord(
            id: UUID(),
            displayWord: "Banana",
            normalizedWord: WordListStore.normalizedWord(for: "Banana"),
            lookupState: .loaded(Self.makeLookupResult(query: "banana", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 21),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(banana, into: defaultCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.removeWords(at: IndexSet(integer: 1))

        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.wordID, banana.id)
        XCTAssertEqual(try store.loadWords(in: defaultCollection.id).map(\.id), [apple.id, banana.id])
    }

    @MainActor
    func testRequestDeleteIncludesOtherCollectionNamesForSharedWord() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )
        viewModel.selectCollection(id: defaultCollection.id)

        viewModel.requestDelete(apple.id)

        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.id, apple.id)
        XCTAssertEqual(pendingWordDeletion.wordID, apple.id)
        XCTAssertEqual(pendingWordDeletion.word, "Apple")
        XCTAssertEqual(pendingWordDeletion.currentCollectionName, "Default")
        XCTAssertEqual(pendingWordDeletion.otherCollectionNames, ["Other"])
    }

    @MainActor
    func testRequestDeleteIgnoresWordOutsideCurrentCollection() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        let banana = PersistedWordRecord(
            id: UUID(),
            displayWord: "Banana",
            normalizedWord: WordListStore.normalizedWord(for: "Banana"),
            lookupState: .loaded(Self.makeLookupResult(query: "banana", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 21),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: otherCollection.id)
        _ = try store.upsertWord(banana, into: defaultCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.requestDelete(apple.id)

        XCTAssertNil(viewModel.pendingWordDeletion)
    }

    @MainActor
    func testInvalidRequestDeleteClearsExistingPendingDeletion() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        let banana = PersistedWordRecord(
            id: UUID(),
            displayWord: "Banana",
            normalizedWord: WordListStore.normalizedWord(for: "Banana"),
            lookupState: .loaded(Self.makeLookupResult(query: "banana", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 21),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(banana, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: defaultCollection.id)
        viewModel.requestDelete(apple.id)
        XCTAssertNotNil(viewModel.pendingWordDeletion)

        viewModel.selectCollection(id: otherCollection.id)
        viewModel.requestDelete(apple.id)

        XCTAssertNil(viewModel.pendingWordDeletion)
    }

    @MainActor
    func testConfirmDeleteEverywhereRemovesWordFromAllCollections() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: Data([0x01]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )
        viewModel.selectCollection(id: defaultCollection.id)

        viewModel.requestDelete(apple.id)
        viewModel.confirmDeletePendingWordEverywhere()

        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertNil(viewModel.selectedWordID)
        XCTAssertNil(viewModel.pendingWordDeletion)
        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
        XCTAssertTrue(try store.loadWords(in: otherCollection.id).isEmpty)
    }

    @MainActor
    func testConfirmDeleteKeepsPendingStateWhenRemovalFails() throws {
        let store = FailingWordListStore()
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.requestDelete(store.apple.id)
        XCTAssertNotNil(viewModel.pendingWordDeletion)

        viewModel.confirmDeletePendingWordEverywhere()

        XCTAssertNotNil(viewModel.pendingWordDeletion)
        XCTAssertTrue(store.removeWordAttempted)
    }

    @MainActor
    func testConfirmDeleteEverywherePartialFailureSyncsUIToStore() throws {
        let store = PartialFailingWordListStore()
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: store.defaultCollection.id)
        viewModel.selectedWordID = store.apple.id
        viewModel.requestDelete(store.apple.id)
        viewModel.confirmDeletePendingWordEverywhere()

        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertNil(viewModel.selectedWordID)
        XCTAssertTrue(try store.loadWords(in: store.defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: store.otherCollection.id).only?.id, store.apple.id)
        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.wordID, store.apple.id)
        XCTAssertEqual(pendingWordDeletion.word, "Apple")
        XCTAssertEqual(pendingWordDeletion.currentCollectionName, "Other")
        XCTAssertEqual(pendingWordDeletion.otherCollectionNames, [])
    }

    @MainActor
    func testConfirmRemovePendingWordFromCurrentCollectionUsesRequestCollectionAfterSwitching() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: defaultCollection.id)
        viewModel.requestDelete(apple.id)
        viewModel.selectCollection(id: otherCollection.id)
        viewModel.confirmRemovePendingWordFromCurrentCollection()

        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: otherCollection.id).only?.id, apple.id)
        XCTAssertEqual(viewModel.words.map(\.id), [apple.id])
        XCTAssertNil(viewModel.pendingWordDeletion)
    }

    @MainActor
    func testConfirmRemovePendingWordFromCurrentCollectionKeepsSharedWordElsewhere() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        let item = try XCTUnwrap(viewModel.words.only)
        viewModel.selectedWordID = item.id
        viewModel.removeWord(item)

        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.wordID, apple.id)
        XCTAssertEqual(pendingWordDeletion.currentCollectionName, "Default")
        XCTAssertEqual(pendingWordDeletion.otherCollectionNames, ["Other"])

        viewModel.confirmRemovePendingWordFromCurrentCollection()

        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: otherCollection.id).only?.id, apple.id)
        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertNil(viewModel.selectedWordID)
        XCTAssertNil(viewModel.pendingWordDeletion)
    }

    @MainActor
    func testConfirmRemovePendingWordFromCurrentCollectionClearsSelectionAndWords() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: defaultCollection.id)
        viewModel.selectedWordID = apple.id
        viewModel.requestDelete(apple.id)
        viewModel.confirmRemovePendingWordFromCurrentCollection()

        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertNil(viewModel.selectedWordID)
        XCTAssertNil(viewModel.pendingWordDeletion)
        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).isEmpty)
    }

    @MainActor
    func testConfirmRemovePendingWordFromCurrentCollectionFailureRebuildsPendingFromRemainingMembership() throws {
        let store = RemoveCurrentCollectionPartialFailingWordListStore()
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: store.defaultCollection.id)
        viewModel.selectedWordID = store.apple.id
        viewModel.requestDelete(store.apple.id)
        viewModel.confirmRemovePendingWordFromCurrentCollection()

        XCTAssertTrue(viewModel.words.isEmpty)
        XCTAssertNil(viewModel.selectedWordID)
        XCTAssertTrue(try store.loadWords(in: store.defaultCollection.id).isEmpty)
        XCTAssertEqual(try store.loadWords(in: store.otherCollection.id).only?.id, store.apple.id)
        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.wordID, store.apple.id)
        XCTAssertEqual(pendingWordDeletion.word, "Apple")
        XCTAssertEqual(pendingWordDeletion.currentCollectionName, "Other")
        XCTAssertEqual(pendingWordDeletion.otherCollectionNames, [])
    }

    @MainActor
    func testCancelPendingWordDeletionClearsDeletionState() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: defaultCollection.id)
        viewModel.requestDelete(apple.id)
        viewModel.cancelPendingWordDeletion()
        viewModel.confirmRemovePendingWordFromCurrentCollection()

        XCTAssertNil(viewModel.pendingWordDeletion)
        XCTAssertTrue(try store.loadWords(in: defaultCollection.id).contains(where: { $0.id == apple.id }))
        XCTAssertTrue(try store.loadWords(in: otherCollection.id).contains(where: { $0.id == apple.id }))
    }

    @MainActor
    func testReloadCurrentWordsRebuildsPendingDeletionAfterExternalMembershipChange() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let otherCollection = try store.createCollection(name: "Other", deckName: nil)
        let apple = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit")),
            audioData: nil,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(apple, into: defaultCollection.id)
        _ = try store.upsertWord(apple, into: otherCollection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in Self.makeLookupResult(query: "apple", definition: "fruit") },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        viewModel.selectCollection(id: defaultCollection.id)
        viewModel.requestDelete(apple.id)
        XCTAssertEqual(try XCTUnwrap(viewModel.pendingWordDeletion).currentCollectionName, "Default")

        try store.removeWord(id: apple.id, from: defaultCollection.id)
        viewModel.selectCollection(id: otherCollection.id)

        XCTAssertEqual(viewModel.words.map(\.id), [apple.id])
        let pendingWordDeletion = try XCTUnwrap(viewModel.pendingWordDeletion)
        XCTAssertEqual(pendingWordDeletion.wordID, apple.id)
        XCTAssertEqual(pendingWordDeletion.currentCollectionName, "Other")
        XCTAssertEqual(pendingWordDeletion.otherCollectionNames, [])
    }

    @MainActor
    func testSelectingWordRefreshesSnapshotAndClearsStaleAudioWhenLookupChanges() async throws {
        let store = try makeStore()
        let collection = try XCTUnwrap(try store.loadCollections().only)
        let initialResult = Self.makeLookupResult(query: "apple", definition: "fruit")
        let refreshedResult = Self.makeLookupResult(query: "apple", definition: "fresh fruit")
        let record = PersistedWordRecord(
            id: UUID(),
            displayWord: "Apple",
            normalizedWord: WordListStore.normalizedWord(for: "Apple"),
            lookupState: .loaded(initialResult),
            audioData: Data([0x01, 0x02]),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            lastRefreshedAt: nil
        )
        _ = try store.upsertWord(record, into: collection.id)
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _ in refreshedResult },
            speak: { _ in },
            synthesize: { _ in Data() }
        )

        let item = try XCTUnwrap(viewModel.words.only)
        viewModel.selectedWordID = item.id
        await viewModel.waitForIdle()

        XCTAssertEqual(item.lookupResult, refreshedResult)
        XCTAssertNil(item.audioData)
        XCTAssertEqual(try store.loadWords(in: collection.id).only?.lookupState, .loaded(refreshedResult))
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

private final class FailingWordListStore: WordListStoring {
    let defaultCollection = PersistedCollectionRecord(
        id: UUID(),
        name: "Default",
        ankiDeckName: "Default",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )

    let apple = PersistedWordRecord(
        id: UUID(),
        displayWord: "Apple",
        normalizedWord: WordListStore.normalizedWord(for: "Apple"),
        lookupState: .loaded(
            LookupResult(
                query: "apple",
                entries: [],
                metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
                source: nil
            )
        ),
        audioData: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        lastRefreshedAt: nil
    )

    var removeWordAttempted = false

    func loadCollections() throws -> [PersistedCollectionRecord] {
        [defaultCollection]
    }

    func createCollection(name: String, deckName: String?) throws -> PersistedCollectionRecord {
        defaultCollection
    }

    func renameCollection(id: UUID, name: String, deckName: String?) throws -> PersistedCollectionRecord {
        defaultCollection
    }

    func deleteCollection(id: UUID) throws {}

    func loadWords(in collectionID: UUID) throws -> [PersistedWordRecord] {
        collectionID == defaultCollection.id ? [apple] : []
    }

    func loadAllWords() throws -> [PersistedWordRecord] {
        [apple]
    }

    func upsertWord(_ record: PersistedWordRecord, into collectionID: UUID) throws -> PersistedWordUpsertResult {
        PersistedWordUpsertResult(record: record, insertedWord: true, insertedAssociation: true)
    }

    func saveWord(_ record: PersistedWordRecord) throws {}

    func removeWord(id: UUID, from collectionID: UUID) throws {
        removeWordAttempted = true
        throw WordListStoreError.sqlError("forced failure")
    }
}

private final class PartialFailingWordListStore: WordListStoring {
    let defaultCollection = PersistedCollectionRecord(
        id: UUID(),
        name: "Default",
        ankiDeckName: "Default",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let otherCollection = PersistedCollectionRecord(
        id: UUID(),
        name: "Other",
        ankiDeckName: "Other",
        createdAt: Date(timeIntervalSince1970: 2),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let apple = PersistedWordRecord(
        id: UUID(),
        displayWord: "Apple",
        normalizedWord: WordListStore.normalizedWord(for: "Apple"),
        lookupState: .loaded(
            LookupResult(
                query: "apple",
                entries: [],
                metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
                source: nil
            )
        ),
        audioData: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        lastRefreshedAt: nil
    )

    private var memberships: [UUID: Set<UUID>]

    init() {
        memberships = [:]
        memberships[defaultCollection.id] = [apple.id]
        memberships[otherCollection.id] = [apple.id]
    }

    func loadCollections() throws -> [PersistedCollectionRecord] {
        [defaultCollection, otherCollection]
    }

    func createCollection(name: String, deckName: String?) throws -> PersistedCollectionRecord {
        defaultCollection
    }

    func renameCollection(id: UUID, name: String, deckName: String?) throws -> PersistedCollectionRecord {
        defaultCollection
    }

    func deleteCollection(id: UUID) throws {}

    func loadWords(in collectionID: UUID) throws -> [PersistedWordRecord] {
        memberships[collectionID, default: []].contains(apple.id) ? [apple] : []
    }

    func loadAllWords() throws -> [PersistedWordRecord] {
        memberships.values.contains(where: { $0.contains(apple.id) }) ? [apple] : []
    }

    func upsertWord(_ record: PersistedWordRecord, into collectionID: UUID) throws -> PersistedWordUpsertResult {
        memberships[collectionID, default: []].insert(record.id)
        return PersistedWordUpsertResult(record: record, insertedWord: true, insertedAssociation: true)
    }

    func saveWord(_ record: PersistedWordRecord) throws {}

    func removeWord(id: UUID, from collectionID: UUID) throws {
        if collectionID == otherCollection.id {
            throw WordListStoreError.sqlError("forced partial failure")
        }
        memberships[collectionID, default: []].remove(id)
    }
}

private final class RemoveCurrentCollectionPartialFailingWordListStore: WordListStoring {
    let defaultCollection = PersistedCollectionRecord(
        id: UUID(),
        name: "Default",
        ankiDeckName: "Default",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1)
    )
    let otherCollection = PersistedCollectionRecord(
        id: UUID(),
        name: "Other",
        ankiDeckName: "Other",
        createdAt: Date(timeIntervalSince1970: 2),
        updatedAt: Date(timeIntervalSince1970: 2)
    )
    let apple = PersistedWordRecord(
        id: UUID(),
        displayWord: "Apple",
        normalizedWord: WordListStore.normalizedWord(for: "Apple"),
        lookupState: .loaded(
            LookupResult(
                query: "apple",
                entries: [],
                metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
                source: nil
            )
        ),
        audioData: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1),
        lastRefreshedAt: nil
    )

    private var memberships: [UUID: Set<UUID>]

    init() {
        memberships = [:]
        memberships[defaultCollection.id] = [apple.id]
        memberships[otherCollection.id] = [apple.id]
    }

    func loadCollections() throws -> [PersistedCollectionRecord] {
        [defaultCollection, otherCollection]
    }

    func createCollection(name: String, deckName: String?) throws -> PersistedCollectionRecord {
        defaultCollection
    }

    func renameCollection(id: UUID, name: String, deckName: String?) throws -> PersistedCollectionRecord {
        defaultCollection
    }

    func deleteCollection(id: UUID) throws {}

    func loadWords(in collectionID: UUID) throws -> [PersistedWordRecord] {
        memberships[collectionID, default: []].contains(apple.id) ? [apple] : []
    }

    func loadAllWords() throws -> [PersistedWordRecord] {
        memberships.values.contains(where: { $0.contains(apple.id) }) ? [apple] : []
    }

    func upsertWord(_ record: PersistedWordRecord, into collectionID: UUID) throws -> PersistedWordUpsertResult {
        memberships[collectionID, default: []].insert(record.id)
        return PersistedWordUpsertResult(record: record, insertedWord: true, insertedAssociation: true)
    }

    func saveWord(_ record: PersistedWordRecord) throws {}

    func removeWord(id: UUID, from collectionID: UUID) throws {
        if collectionID == defaultCollection.id {
            memberships[collectionID, default: []].remove(id)
            throw WordListStoreError.sqlError("forced partial failure")
        }
        memberships[collectionID, default: []].remove(id)
    }
}
