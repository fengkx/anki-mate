import DictKit
import DictKitAnkiExport
import DictKitSystemDictionary
import Foundation
import Combine
import SQLite3
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

    func testPlayPronunciationPersistsAudioWhenMissing() async throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let itemID = UUID()
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: itemID,
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

        let expectedAudio = Data([0x01, 0x02, 0x03])
        let speakCount = CallCounter()
        let synthesizeCount = CallCounter()
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _, _ in
                Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])
            },
            speak: { _ in
                await speakCount.increment()
            },
            synthesize: { _ in
                await synthesizeCount.increment()
                return expectedAudio
            }
        )

        let item = try XCTUnwrap(viewModel.words.only)
        await viewModel.playPronunciation(for: item)

        let recordedSpeakCount = await speakCount.value
        let recordedSynthesizeCount = await synthesizeCount.value
        XCTAssertEqual(recordedSpeakCount, 1)
        XCTAssertEqual(recordedSynthesizeCount, 1)
        XCTAssertEqual(item.audioData, expectedAudio)

        let persisted = try XCTUnwrap(try store.loadWords(in: defaultCollection.id).first(where: { $0.id == itemID }))
        XCTAssertEqual(persisted.audioData, expectedAudio)
    }

    func testRefreshPronunciationAudioReplacesSavedAudio() async throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let itemID = UUID()
        let initialAudio = Data([0xAA])
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: itemID,
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
                audioData: initialAudio,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )

        let refreshedAudio = Data([0xBB, 0xCC])
        let synthesizeCount = CallCounter()
        let viewModel = try WordListViewModel(
            store: store,
            lookup: { _, _ in
                Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])
            },
            speak: { _ in },
            synthesize: { _ in
                await synthesizeCount.increment()
                return refreshedAudio
            }
        )

        let item = try XCTUnwrap(viewModel.words.only)
        await viewModel.refreshPronunciationAudio(for: item)

        let recordedSynthesizeCount = await synthesizeCount.value
        XCTAssertEqual(recordedSynthesizeCount, 1)
        XCTAssertEqual(item.audioData, refreshedAudio)

        let persisted = try XCTUnwrap(try store.loadWords(in: defaultCollection.id).first(where: { $0.id == itemID }))
        XCTAssertEqual(persisted.audioData, refreshedAudio)
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
        XCTAssertEqual(reloaded.aiArtifacts.acceptedExampleSentences, ["An apple a day keeps the doctor away."])
        XCTAssertEqual(reloaded.aiArtifacts.acceptedDefinitionNoteText, "A learner-friendly definition.")
    }

    func testExampleArtifactsNormalizeStructuredFieldsAcrossPersistenceReload() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let rawArtifacts = try JSONDecoder().decode(
            AIArtifacts.self,
            from: Data(
                """
                {
                  "schemaVersion": 1,
                  "exampleSentences": {
                    "suggested": [
                      {
                        "text": "Suggested example",
                        "translation": "建议翻译"
                      }
                    ],
                    "accepted": [
                      {
                        "text": "Accepted example — 新翻译",
                        "translation": "stale translation",
                        "note": "  keep note  "
                      }
                    ]
                  }
                }
                """.utf8
            )
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
                lastRefreshedAt: nil,
                aiArtifacts: rawArtifacts
            ),
            into: defaultCollection.id
        )

        let viewModel = try makeViewModel(store: store)
        let item = try XCTUnwrap(viewModel.words.only)

        XCTAssertEqual(item.aiSuggestedExampleArtifacts.only?.text, "Suggested example — 建议翻译")
        XCTAssertEqual(item.aiSuggestedExampleArtifacts.only?.translation, "建议翻译")
        XCTAssertEqual(item.aiAcceptedExampleArtifacts.only?.text, "Accepted example — 新翻译")
        XCTAssertEqual(item.aiAcceptedExampleArtifacts.only?.translation, "新翻译")
        XCTAssertEqual(item.aiAcceptedExampleArtifacts.only?.note, "keep note")

        viewModel.saveAIAcceptedExampleArtifacts(
            [
                ExampleSentenceArtifact(
                    text: "Edited example — 编辑后翻译",
                    translation: "outdated",
                    note: "  updated note  "
                )
            ],
            for: item
        )
        viewModel.reloadFromStore()

        let reloaded = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(reloaded.aiAcceptedExampleArtifacts.only?.text, "Edited example — 编辑后翻译")
        XCTAssertEqual(reloaded.aiAcceptedExampleArtifacts.only?.translation, "编辑后翻译")
        XCTAssertEqual(reloaded.aiAcceptedExampleArtifacts.only?.note, "updated note")
    }

    func testUnifiedAIArtifactsPersistReservedTypesAcrossReload() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        let artifacts = AIArtifacts(
            recallCardDrafts: AIArtifactSlot(
                accepted: [
                    RecallCardDraft(
                        mode: .phraseRecall,
                        front: "The committee reached a ____.",
                        back: "consensus",
                        hint: "noun"
                    )
                ]
            ),
            pitfalls: AIArtifactSlot(
                accepted: [PitfallArtifact(text: "Do not confuse it with consent.")]
            ),
            mnemonics: AIArtifactSlot(
                accepted: [MnemonicArtifact(text: "Consensus sounds like everyone says yes together.")]
            ),
            collocations: AIArtifactSlot(
                accepted: [CollocationArtifact(phrase: "reach a consensus", note: "common academic collocation")]
            ),
            learningAidSelections: LearningAidSelections(
                pitfalls: LearningAidSectionSelection(
                    recommendedID: "pitfall-1",
                    alternativeIDs: ["pitfall-2"],
                    overlapHints: [
                        LearningAidSelectionOverlapHint(
                            candidateID: "pitfall-2",
                            overlapType: "accepted_overlap",
                            withItemID: "pitfalls-accepted-0",
                            reason: "Covers the same contrast."
                        )
                    ],
                    whyRecommended: "Most specific warning.",
                    selectionSource: "judge_with_guardrails"
                )
            )
        )
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Consensus",
                normalizedWord: WordListStore.normalizedWord(for: "Consensus"),
                lookupState: .loaded(Self.makeLookupResult(query: "consensus", definition: "general agreement", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil,
                aiArtifacts: artifacts
            ),
            into: defaultCollection.id
        )

        let viewModel = try makeViewModel(store: store)
        let reloaded = try XCTUnwrap(viewModel.words.only)

        XCTAssertEqual(reloaded.aiArtifacts, artifacts)
        XCTAssertEqual(reloaded.aiAcceptedRecallCardDrafts.count, 1)
        XCTAssertEqual(reloaded.aiAcceptedPitfalls, ["Do not confuse it with consent."])
        XCTAssertEqual(reloaded.aiAcceptedMnemonics, ["Consensus sounds like everyone says yes together."])
        XCTAssertEqual(reloaded.aiAcceptedCollocations, ["reach a consensus"])
        XCTAssertEqual(reloaded.aiArtifacts.learningAidSelections.pitfalls?.recommendedID, "pitfall-1")
    }

    func testAIArtifactSaveHelpersPersistUnifiedSlots() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)
        let defaultCollection = try XCTUnwrap(viewModel.currentCollection)
        let item = WordItem(word: "Consensus")
        _ = try store.upsertWord(PersistedWordRecord(item: item), into: defaultCollection.id)
        viewModel.reloadFromStore()
        let reloadedItem = try XCTUnwrap(viewModel.words.only)

        viewModel.saveAISuggestedRecallCardDrafts([
            RecallCardDraft(mode: .phraseRecall, front: "The committee reached a ____.", back: "consensus")
        ], for: reloadedItem)
        viewModel.saveAIAcceptedRecallCardDrafts([
            RecallCardDraft(mode: .phraseRecall, front: "first draft", back: "first answer"),
            RecallCardDraft(mode: .fullSpelling, front: "c_nse_sus", back: "consensus", hint: "noun")
        ], for: reloadedItem)
        viewModel.saveAISuggestedPitfalls(["Do not confuse it with consent."], for: reloadedItem)
        viewModel.saveAIAcceptedPitfalls(["Avoid using it for general agreement in every context."], for: reloadedItem)
        viewModel.saveAISuggestedMnemonics(["Consensus sounds like everyone says yes together."], for: reloadedItem)
        viewModel.saveAIAcceptedMnemonics(["Say it together, then settle on consensus."], for: reloadedItem)
        viewModel.saveAISuggestedCollocations(["reach a consensus"], for: reloadedItem)
        viewModel.saveAIAcceptedCollocations(["arrive at a consensus"], for: reloadedItem)

        viewModel.reloadFromStore()

        let reloaded = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(reloaded.aiSuggestedRecallCardDrafts.count, 1)
        XCTAssertEqual(reloaded.aiAcceptedRecallCardDrafts.count, 1)
        XCTAssertEqual(reloaded.aiAcceptedRecallCardDrafts.first?.front, "c_nse_sus")
        XCTAssertEqual(reloaded.aiSuggestedPitfalls, ["Do not confuse it with consent."])
        XCTAssertEqual(reloaded.aiAcceptedPitfalls, ["Avoid using it for general agreement in every context."])
        XCTAssertEqual(reloaded.aiSuggestedMnemonics, ["Consensus sounds like everyone says yes together."])
        XCTAssertEqual(reloaded.aiAcceptedMnemonics, ["Say it together, then settle on consensus."])
        XCTAssertEqual(reloaded.aiSuggestedCollocations, ["reach a consensus"])
        XCTAssertEqual(reloaded.aiAcceptedCollocations, ["arrive at a consensus"])
    }

    func testLearningAidSelectionPersistsAcrossReload() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)
        let defaultCollection = try XCTUnwrap(viewModel.currentCollection)
        let item = WordItem(word: "Consensus")
        _ = try store.upsertWord(PersistedWordRecord(item: item), into: defaultCollection.id)
        viewModel.reloadFromStore()
        let reloadedItem = try XCTUnwrap(viewModel.words.only)

        let selection = LearningAidSectionSelection(
            recommendedID: "pitfall-1",
            alternativeIDs: ["pitfall-2"],
            overlapHints: [
                LearningAidSelectionOverlapHint(
                    candidateID: "pitfall-2",
                    overlapType: "accepted_overlap",
                    withItemID: "pitfalls-accepted-0",
                    reason: "Covers the same contrast."
                )
            ],
            whyRecommended: "Most specific warning.",
            selectionSource: "judge_with_guardrails"
        )

        viewModel.saveLearningAidSelection(selection, for: .pitfalls, item: reloadedItem)
        viewModel.reloadFromStore()

        let persisted = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(persisted.aiArtifacts.learningAidSelections.pitfalls, selection)
    }

    func testStructuredExampleArtifactsPersistMetadataAcrossReload() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)
        let defaultCollection = try XCTUnwrap(viewModel.currentCollection)
        let item = WordItem(word: "Charge")
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: item.id,
                displayWord: "Charge",
                normalizedWord: WordListStore.normalizedWord(for: "Charge"),
                lookupState: .loaded(Self.makeLookupResult(query: "charge", definition: "formal accusation", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )
        viewModel.reloadFromStore()
        let reloadedItem = try XCTUnwrap(viewModel.words.only)

        let suggested = ExampleSentenceArtifact(
            text: "The lawyer filed a charge yesterday — 律师昨天提起了指控。",
            translation: "律师昨天提起了指控。",
            anchor: AIArtifactAnchorSnapshot(
                headword: "charge",
                lexicalEntryIndex: 0,
                senseIndex: 0,
                exampleIndex: nil,
                excerpt: "formal accusation"
            )
        )
        let accepted = ExampleSentenceArtifact(
            text: "The store may charge extra for delivery — 商店可能会额外收取配送费。",
            translation: "商店可能会额外收取配送费。",
            anchor: AIArtifactAnchorSnapshot(
                headword: "charge",
                lexicalEntryIndex: 1,
                senseIndex: 0,
                exampleIndex: nil,
                excerpt: "ask someone to pay a price"
            )
        )

        viewModel.saveAISuggestedExampleArtifacts([suggested], for: reloadedItem)
        viewModel.saveAIAcceptedExampleArtifacts([accepted], for: reloadedItem)
        viewModel.reloadFromStore()

        let reloaded = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(reloaded.aiSuggestedExampleArtifacts, [suggested])
        XCTAssertEqual(reloaded.aiAcceptedExampleArtifacts, [accepted])
        XCTAssertEqual(reloaded.aiSuggestedExampleSentences, [suggested.text])
        XCTAssertEqual(reloaded.aiAcceptedExampleSentences, [accepted.text])
    }

    func testEditedAcceptedExampleArtifactPersistsWithoutStaleTranslation() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)
        let defaultCollection = try XCTUnwrap(viewModel.currentCollection)
        let item = WordItem(word: "Charge")
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: item.id,
                displayWord: "Charge",
                normalizedWord: WordListStore.normalizedWord(for: "Charge"),
                lookupState: .loaded(Self.makeLookupResult(query: "charge", definition: "formal accusation", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: defaultCollection.id
        )
        viewModel.reloadFromStore()
        let reloadedItem = try XCTUnwrap(viewModel.words.only)

        let original = ExampleSentenceArtifact(
            text: "The lawyer filed a charge yesterday — 律师昨天提起了指控。",
            translation: "律师昨天提起了指控。"
        )
        viewModel.saveAIAcceptedExampleArtifacts([original], for: reloadedItem)
        viewModel.saveAIAcceptedExampleArtifacts([
            ExampleSentenceArtifact(
                text: "The lawyer filed a charge again",
                translation: original.translation
            )
        ], for: reloadedItem)
        viewModel.reloadFromStore()

        let persisted = try XCTUnwrap(viewModel.words.only?.aiAcceptedExampleArtifacts.only)
        XCTAssertEqual(persisted.text, "The lawyer filed a charge again")
        XCTAssertNil(persisted.translation)
    }

    func testAIArtifactsRoundTripUnifiedSchemaAndLegacyCompatibility() throws {
        let artifacts = AIArtifacts(
            schemaVersion: AIArtifacts.currentSchemaVersion,
            exampleSentences: AIArtifactSlot(
                suggested: [
                    ExampleSentenceArtifact(text: "Suggested example.", note: "keep it short")
                ],
                accepted: [
                    ExampleSentenceArtifact(
                        text: "Accepted example.",
                        translation: "示例句"
                    )
                ]
            ),
            definitionNote: AIArtifactSlot(
                accepted: DefinitionNoteArtifact(text: "Keep the learner-facing note brief.")
            ),
            recallCardDrafts: AIArtifactSlot(
                accepted: [
                    RecallCardDraft(
                        mode: .phraseRecall,
                        front: "The committee reached a ____.",
                        back: "consensus",
                        hint: "noun",
                        anchor: AIArtifactAnchorSnapshot(
                            headword: "consensus",
                            lexicalEntryIndex: 0,
                            senseIndex: 0,
                            exampleIndex: nil,
                            excerpt: "reached a consensus"
                        )
                    )
                ]
            ),
            pitfalls: AIArtifactSlot(
                accepted: [PitfallArtifact(text: "Do not confuse it with consent.")]
            ),
            mnemonics: AIArtifactSlot(
                accepted: [MnemonicArtifact(text: "Consensus sounds like everyone says yes together.")]
            ),
            collocations: AIArtifactSlot(
                accepted: [CollocationArtifact(phrase: "reach a consensus", note: "common academic collocation")]
            ),
            generatedIPANotationsByDialect: ["AmE": "kənˈsɛnsəs"],
            generatedStressSyllablesByDialect: ["AmE": "con-SEN-sus"]
        )

        let encoded = try JSONEncoder().encode(artifacts)
        let decoded = try JSONDecoder().decode(AIArtifacts.self, from: encoded)

        XCTAssertEqual(decoded, artifacts)
        XCTAssertEqual(decoded.schemaVersion, AIArtifacts.currentSchemaVersion)
        XCTAssertEqual(decoded.acceptedExampleSentences, ["Accepted example."])
        XCTAssertEqual(decoded.acceptedDefinitionNoteText, "Keep the learner-facing note brief.")
        XCTAssertEqual(decoded.acceptedPitfallTexts, ["Do not confuse it with consent."])
        XCTAssertEqual(decoded.acceptedMnemonicTexts, ["Consensus sounds like everyone says yes together."])
        XCTAssertEqual(decoded.acceptedCollocationPhrases, ["reach a consensus"])
        XCTAssertEqual(decoded.generatedIPANotationsByDialect["AmE"], "kənˈsɛnsəs")
        XCTAssertEqual(decoded.generatedStressSyllablesByDialect["AmE"], "con-SEN-sus")
        XCTAssertFalse(decoded.isEmpty)
    }

    func testAIArtifactsFillsMissingSlotsFromLegacyFieldsWithoutClobberingUnifiedValues() {
        let unified = AIArtifacts(
            recallCardDrafts: AIArtifactSlot(
                accepted: [
                    RecallCardDraft(mode: .fullSpelling, front: "take ___", back: "off")
                ]
            )
        )

        let merged = unified.fillingMissingSlots(
            legacyAcceptedExampleSentences: ["Legacy example."],
            legacyAcceptedDefinitionNote: "Legacy definition note.",
            legacyAcceptedRecallCardDrafts: [
                RecallCardDraft(mode: .phraseRecall, front: "do not use", back: "legacy")
            ],
            legacyAcceptedPitfalls: ["Legacy pitfall."],
            legacyAcceptedMnemonics: ["Legacy mnemonic."],
            legacyAcceptedCollocations: ["Legacy collocation."]
        )

        XCTAssertEqual(merged.acceptedExampleSentences, ["Legacy example."])
        XCTAssertEqual(merged.acceptedDefinitionNoteText, "Legacy definition note.")
        XCTAssertEqual(merged.acceptedRecallCardDrafts.count, 1)
        XCTAssertEqual(merged.acceptedRecallCardDrafts.first?.mode, .fullSpelling)
        XCTAssertEqual(merged.acceptedRecallCardDrafts.first?.front, "take ___")
        XCTAssertEqual(merged.acceptedPitfallTexts, ["Legacy pitfall."])
        XCTAssertEqual(merged.acceptedMnemonicTexts, ["Legacy mnemonic."])
        XCTAssertEqual(merged.acceptedCollocationPhrases, ["Legacy collocation."])
    }

    func testLegacyAIColumnsMigrateIntoUnifiedSchema() throws {
        let store = try makeStore()
        let defaultCollection = try XCTUnwrap(try store.loadCollections().only)
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: "apple",
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil,
                aiArtifacts: .empty,
                aiSuggestedExampleSentences: ["Suggested example."],
                aiAcceptedExampleSentences: ["Accepted example."],
                aiSuggestedDefinitionNote: "Suggested definition.",
                aiAcceptedDefinitionNote: "Accepted definition."
            ),
            into: defaultCollection.id
        )

        let migrated = try XCTUnwrap(try store.loadWords(in: defaultCollection.id).only)

        XCTAssertEqual(migrated.aiArtifacts.suggestedExampleSentences, ["Suggested example."])
        XCTAssertEqual(migrated.aiArtifacts.acceptedExampleSentences, ["Accepted example."])
        XCTAssertEqual(migrated.aiArtifacts.suggestedDefinitionNoteText, "Suggested definition.")
        XCTAssertEqual(migrated.aiArtifacts.acceptedDefinitionNoteText, "Accepted definition.")

        try store.withDatabase { db in
            let sql = "SELECT ai_artifacts_json FROM word_payloads LIMIT 1"
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
            let json = String(cString: sqlite3_column_text(stmt, 0))
            XCTAssertTrue(json.contains("\"schemaVersion\":4"))
            XCTAssertTrue(json.contains("Accepted example."))
        }
    }

    func testGeneratedIPAPersistsAcrossReload() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)
        let defaultCollection = try XCTUnwrap(viewModel.currentCollection)
        let item = WordItem(word: "collocation")
        _ = try store.upsertWord(PersistedWordRecord(item: item), into: defaultCollection.id)
        viewModel.reloadFromStore()
        let reloadedItem = try XCTUnwrap(viewModel.words.only)

        viewModel.saveGeneratedIPA("ˌkɑləˈkeɪʃən", dialect: "AmE", for: reloadedItem)
        viewModel.reloadFromStore()

        let persisted = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(persisted.generatedIPANotationsByDialect["AmE"], "ˌkɑləˈkeɪʃən")
        XCTAssertEqual(persisted.phonetic, "/ˌkɑləˈkeɪʃən/")
    }

    func testGeneratedStressSyllablesPersistAcrossReload() throws {
        let store = try makeStore()
        let viewModel = try makeViewModel(store: store)
        let defaultCollection = try XCTUnwrap(viewModel.currentCollection)
        let item = WordItem(word: "important")
        _ = try store.upsertWord(PersistedWordRecord(item: item), into: defaultCollection.id)
        viewModel.reloadFromStore()
        let reloadedItem = try XCTUnwrap(viewModel.words.only)

        viewModel.saveGeneratedStressSyllables("im-POR-tant", dialect: "AmE", for: reloadedItem)
        viewModel.reloadFromStore()

        let persisted = try XCTUnwrap(viewModel.words.only)
        XCTAssertEqual(persisted.generatedStressSyllablesByDialect["AmE"], "im-POR-tant")
        XCTAssertEqual(persisted.generatedStressSyllables(for: "AmE"), "im-POR-tant")
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

    private func makeLegacySchemaDatabase(
        suggestedExamples: [String],
        acceptedExamples: [String],
        suggestedDefinitionNote: String,
        acceptedDefinitionNote: String
    ) throws -> URL {
        let baseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let databaseURL = baseURL.appendingPathComponent("word-list.sqlite3")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        try execSQL(
            """
            PRAGMA user_version = 9;
            CREATE TABLE collections (
              id TEXT PRIMARY KEY,
              name TEXT NOT NULL COLLATE NOCASE UNIQUE,
              dictionary_name TEXT NOT NULL,
              anki_deck_name TEXT NOT NULL,
              deck_description TEXT NOT NULL,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              is_deleted INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE words (
              id TEXT PRIMARY KEY,
              collection_id TEXT NOT NULL,
              normalized_word TEXT NOT NULL,
              display_word TEXT NOT NULL,
              source_form TEXT,
              inflection_kind TEXT,
              expected_part_of_speech TEXT,
              lookup_state_json BLOB,
              audio_data BLOB,
              created_at REAL NOT NULL,
              updated_at REAL NOT NULL,
              last_refreshed_at REAL,
              is_deleted INTEGER NOT NULL DEFAULT 0,
              audio_hash TEXT,
              ai_suggested_example_sentences TEXT,
              ai_accepted_example_sentences TEXT,
              ai_suggested_definition_note TEXT,
              ai_accepted_definition_note TEXT,
              UNIQUE (collection_id, normalized_word)
            );
            CREATE TABLE sync_metadata (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            );
            """,
            db: db
        )

        let collectionID = UUID()
        let wordID = UUID()
        let lookupState = try JSONEncoder().encode(PersistedLookupState.loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: [])))
        let suggestedExamplesJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(suggestedExamples), encoding: .utf8))
        let acceptedExamplesJSON = try XCTUnwrap(String(data: try JSONEncoder().encode(acceptedExamples), encoding: .utf8))

        try execSQL(
            """
            INSERT INTO collections (id, name, dictionary_name, anki_deck_name, deck_description, created_at, updated_at, is_deleted)
            VALUES ('\(collectionID.uuidString)', 'Default', '', 'Default', '', 10, 10, 0);
            """,
            db: db
        )

        var stmt: OpaquePointer?
        let insertSQL = """
        INSERT INTO words (
          id, collection_id, normalized_word, display_word, source_form, inflection_kind, expected_part_of_speech, lookup_state_json, audio_data, created_at, updated_at, last_refreshed_at, is_deleted, audio_hash, ai_suggested_example_sentences, ai_accepted_example_sentences, ai_suggested_definition_note, ai_accepted_definition_note
        ) VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, NULL, 10, 10, NULL, 0, NULL, ?, ?, ?, ?)
        """
        XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, wordID.uuidString, -1, testTransientDestructor)
        sqlite3_bind_text(stmt, 2, collectionID.uuidString, -1, testTransientDestructor)
        sqlite3_bind_text(stmt, 3, "apple", -1, testTransientDestructor)
        sqlite3_bind_text(stmt, 4, "Apple", -1, testTransientDestructor)
        _ = lookupState.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 5, bytes.baseAddress, Int32(bytes.count), testTransientDestructor)
        }
        sqlite3_bind_text(stmt, 6, suggestedExamplesJSON, -1, testTransientDestructor)
        sqlite3_bind_text(stmt, 7, acceptedExamplesJSON, -1, testTransientDestructor)
        sqlite3_bind_text(stmt, 8, suggestedDefinitionNote, -1, testTransientDestructor)
        sqlite3_bind_text(stmt, 9, acceptedDefinitionNote, -1, testTransientDestructor)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        return databaseURL
    }

    private func execSQL(_ sql: String, db: OpaquePointer?) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        let message = error.map { String(cString: $0) } ?? "unknown"
        XCTAssertEqual(status, SQLITE_OK, message)
        sqlite3_free(error)
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

private actor CallCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    var value: Int {
        count
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private let testTransientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
