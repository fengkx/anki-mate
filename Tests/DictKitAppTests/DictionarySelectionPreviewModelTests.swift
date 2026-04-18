import DictKit
import DictKitSystemDictionary
import XCTest
@testable import DictKitApp

@MainActor
final class DictionarySelectionPreviewModelTests: XCTestCase {
    func testRefreshBuildsDynamicSectionsFromLookupResult() async throws {
        let model = DictionarySelectionPreviewModel(
            currentDictionaryName: "",
            candidateDictionaryName: "Oxford Dictionary of English",
            listDictionaries: { ["Oxford Dictionary of English"] },
            lookup: { term, source in
                switch source {
                case .automatic:
                    return Self.makeLookupResult(
                        query: term,
                        definition: "fruit",
                        examples: ["An apple a day."],
                        phraseGroups: [],
                        notes: []
                    )
                case .privateHTML:
                    return Self.makeLookupResult(
                        query: term,
                        definition: "fruit",
                        examples: ["An apple a day."],
                        phraseGroups: [
                            PhraseGroup(
                                title: "PHRASES",
                                items: [PhraseItem(phrase: "apple of discord", definition: "a cause of dispute", examples: [])],
                                rawContent: nil
                            )
                        ],
                        notes: [Note(kind: .usage, content: "Often used in idioms.")]
                    )
                case .publicAPI:
                    XCTFail("Unexpected lookup source")
                    throw LookupError.notFound
                }
            }
        )

        await model.refresh()

        XCTAssertEqual(model.comparisonState, .loaded)
        let comparison = try XCTUnwrap(model.comparison)
        XCTAssertTrue(comparison.current.sections.contains(where: { $0.kind == .lexicalEntry }))
        XCTAssertTrue(comparison.candidate.sections.contains(where: { $0.kind == .phraseGroup }))
        XCTAssertTrue(comparison.candidate.sections.contains(where: { $0.kind == .note }))
    }

    func testRefreshKeepsRawSectionsAvailableForRendering() async throws {
        let pane = DictionaryPreviewPane(
            title: "Candidate",
            dictionaryName: "Oxford Dictionary of English",
            sections: [
                DictionaryPreviewSection(
                    id: "summary",
                    kind: .summary,
                    title: "Headword",
                    rows: [],
                    isExpandable: false
                ),
                DictionaryPreviewSection(
                    id: "phrases",
                    kind: .phraseGroup,
                    title: "PHRASES",
                    rows: [
                        DictionaryPreviewRow(
                            id: "phrase",
                            label: "apple of discord",
                            value: "a cause of dispute",
                            emphasis: .primary
                        )
                    ],
                    isExpandable: false
                )
            ],
            state: .loaded
        )

        let model = DictionarySelectionPreviewModel(
            currentDictionaryName: "",
            candidateDictionaryName: "",
            listDictionaries: { [] },
            lookup: { _, _ in Self.makeLookupResult(query: "apple", definition: "fruit", examples: [], phraseGroups: [], notes: []) }
        )

        _ = model

        XCTAssertEqual(pane.sections.map(\.kind), [.summary, .phraseGroup])
    }

    func testRefreshMarksPartialFailureWhenOneSideFails() async throws {
        let model = DictionarySelectionPreviewModel(
            currentDictionaryName: "",
            candidateDictionaryName: "Oxford Dictionary of English",
            listDictionaries: { ["Oxford Dictionary of English"] },
            lookup: { term, source in
                switch source {
                case .automatic:
                    return Self.makeLookupResult(query: term, definition: "fruit", examples: [], phraseGroups: [], notes: [])
                case .privateHTML:
                    throw LookupError.sourceUnavailable
                case .publicAPI:
                    throw LookupError.notFound
                }
            }
        )

        await model.refresh()

        XCTAssertEqual(model.comparisonState, .partialFailure)
    }

    func testCurrentDictionaryMatchesCanonicalAvailableName() async throws {
        let model = DictionarySelectionPreviewModel(
            currentDictionaryName: "Oxford Dictionary of English",
            candidateDictionaryName: "Oxford Dictionary of English",
            listDictionaries: {
                ["Oxford Dictionary of English 3rd Edition"]
            },
            lookup: { term, _ in
                Self.makeLookupResult(
                    query: term,
                    definition: "fruit",
                    examples: [],
                    phraseGroups: [],
                    notes: []
                )
            }
        )

        XCTAssertTrue(model.isCurrentDictionary("Oxford Dictionary of English 3rd Edition"))
        XCTAssertTrue(model.isCandidateDictionary("Oxford Dictionary of English 3rd Edition"))
    }

    nonisolated private static func makeLookupResult(
        query: String,
        definition: String,
        examples: [String],
        phraseGroups: [PhraseGroup],
        notes: [Note]
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
                            pronunciations: [],
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
                    phraseGroups: phraseGroups,
                    notes: notes
                )
            ],
            metadata: LookupMetadata(usedSource: .privateHTML, warnings: []),
            source: nil
        )
    }
}
