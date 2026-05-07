import DictKit
import DictKitSystemDictionary
import Foundation
import XCTest
@testable import DictKitApp

@MainActor
final class CommandPaletteViewModelTests: XCTestCase {
    func testPresentShowsRecentWordsAndCommands() throws {
        let dependencies = try makeDependencies()
        let wordID = try XCTUnwrap(dependencies.viewModel.words.first?.id)
        dependencies.historyStore.recordWord(wordID)
        dependencies.historyStore.recordCommand("export")

        dependencies.palette.present()

        XCTAssertTrue(dependencies.palette.isPresented)
        XCTAssertEqual(dependencies.palette.groupedItems.first?.0, .recentWords)
        XCTAssertTrue(dependencies.palette.items.contains {
            if case .command(let item) = $0 {
                return item.id == "export"
            }
            return false
        })
    }

    func testTypingLeadingAngleSwitchesToCommandMode() throws {
        let dependencies = try makeDependencies()

        dependencies.palette.present()
        dependencies.palette.updateQuery(">sync")

        XCTAssertEqual(dependencies.palette.mode, .commands)
        XCTAssertTrue(dependencies.palette.items.contains {
            if case .command(let item) = $0 {
                return item.id == "sync-now"
            }
            return false
        })
    }

    func testValidationAllowsAddRowWhenDictionaryLookupSucceeds() async throws {
        let dependencies = try makeDependencies(rawLookup: { query, source in
            XCTAssertEqual(query, "abandon")
            XCTAssertEqual(source, .publicAPI)
            return Self.makeLookupResult(query: "abandon", definition: "leave behind", examples: ["abandon ship"])
        })

        dependencies.palette.present()
        dependencies.palette.updateQuery("abandon")
        await waitForValidationResult(in: dependencies.palette)

        XCTAssertTrue(dependencies.palette.canAddCurrentQuery)
        XCTAssertFalse(dependencies.palette.items.contains {
            if case .addWord = $0 { return true }
            return false
        })
        let preview = try XCTUnwrap(dependencies.palette.addWordPreview)
        XCTAssertEqual(preview.query, "abandon")
        XCTAssertEqual(preview.canonicalWord, "abandon")
        XCTAssertEqual(preview.definition, "leave behind")
        XCTAssertTrue(preview.isAddable)
    }

    func testValidationReportsDuplicateWordPreview() async throws {
        let dependencies = try makeDependencies()

        dependencies.palette.present()
        dependencies.palette.updateQuery("Apple")
        await waitForValidationResult(in: dependencies.palette)

        XCTAssertFalse(dependencies.palette.canAddCurrentQuery)
        let preview = try XCTUnwrap(dependencies.palette.addWordPreview)
        XCTAssertEqual(preview.status, .duplicateExistingWord)
        XCTAssertEqual(preview.query, "Apple")
        XCTAssertFalse(preview.isAddable)
    }

    func testExecuteWordSelectsWordAndRecordsHistory() throws {
        let dependencies = try makeDependencies()
        let word = try XCTUnwrap(dependencies.viewModel.words.first)

        dependencies.palette.present()
        dependencies.palette.execute(.word(.init(
            wordID: word.id,
            title: word.word,
            subtitle: nil,
            trailingText: "Ready",
            isRecent: false
        )))

        XCTAssertEqual(dependencies.viewModel.selectedWordID, word.id)
        XCTAssertEqual(dependencies.historyStore.load().recentWordIDs, [word.id])
        XCTAssertFalse(dependencies.palette.isPresented)
    }

    func testSwitchCollectionCommandEntersCollectionMode() throws {
        let dependencies = try makeDependencies()

        dependencies.palette.present()
        dependencies.palette.execute(.command(.init(
            id: "switch-collection",
            title: "Switch Collection",
            subtitle: "",
            systemImage: "books.vertical",
            keywords: []
        )))

        XCTAssertEqual(dependencies.palette.mode, .collections)
        XCTAssertTrue(dependencies.palette.items.contains {
            if case .collection = $0 { return true }
            return false
        })
    }

    private func makeDependencies() throws -> (viewModel: WordListViewModel, palette: CommandPaletteViewModel, historyStore: CommandPaletteHistoryStore) {
        try makeDependencies(rawLookup: { _, _ in
            Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])
        })
    }

    private func makeDependencies(
        rawLookup: @escaping @Sendable (String, DictionaryLookupSource) async throws -> LookupResult
    ) throws -> (viewModel: WordListViewModel, palette: CommandPaletteViewModel, historyStore: CommandPaletteHistoryStore) {
        let store = try makeStore()
        let collection = try XCTUnwrap(store.loadCollections().first)
        _ = try store.upsertWord(
            PersistedWordRecord(
                id: UUID(),
                displayWord: "Apple",
                normalizedWord: WordListStore.normalizedWord(for: "Apple"),
                lookupState: .loaded(Self.makeLookupResult(query: "apple", definition: "fruit", examples: ["I ate an apple"])),
                audioData: nil,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10),
                lastRefreshedAt: nil
            ),
            into: collection.id
        )

        let viewModel = try WordListViewModel(
            store: store,
            lookup: rawLookup,
            speak: { _ in },
            synthesize: { _ in Data() }
        )
        let historyStore = CommandPaletteHistoryStore(defaults: UserDefaults(suiteName: "CommandPaletteViewModelTests.\(UUID().uuidString)")!)
        let palette = CommandPaletteViewModel(wordListViewModel: viewModel, historyStore: historyStore)
        palette.configure(actions: .init(
            openBatchAdd: {},
            openExport: {},
            openNewCollection: {},
            openCollectionSettings: {},
            openWindow: { _ in },
            syncNow: {}
        ))
        return (viewModel, palette, historyStore)
    }

    private func makeStore() throws -> WordListStore {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try WordListStore(databaseURL: baseURL.appendingPathComponent("word-list.sqlite3"))
    }

    nonisolated private static func makeLookupResult(
        query: String,
        definition: String,
        examples: [String]
    ) -> LookupResult {
        LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: query,
                    pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)],
                    lexicalEntries: [
                        LexicalEntry(
                            partOfSpeech: .noun,
                            partOfSpeechLabel: "noun",
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

    private func waitForValidationResult(in palette: CommandPaletteViewModel) async {
        for _ in 0..<20 {
            if case .result = palette.lookupValidationState {
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
