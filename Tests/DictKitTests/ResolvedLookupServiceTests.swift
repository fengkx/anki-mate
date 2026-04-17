import DictKit
import DictKitSystemDictionary
import XCTest

final class ResolvedLookupServiceTests: XCTestCase {
    func testResolvePastFormToLemmaAndVerbPriority() async throws {
        let service = ResolvedLookupService(
            lookup: { term, _ in
                switch term {
                case "flock":
                    return Self.makeLookupResult(
                        query: "flock",
                        headword: "flock",
                        lexicalEntries: [
                            Self.makeLexicalEntry(
                                partOfSpeech: .noun,
                                label: "noun",
                                definition: "a group of birds",
                                inflections: []
                            ),
                            Self.makeLexicalEntry(
                                partOfSpeech: .verb,
                                label: "verb",
                                definition: "to gather in a flock",
                                inflections: ["flocked"]
                            ),
                        ]
                    )
                case "flocked":
                    return Self.makeLookupResult(
                        query: "flocked",
                        headword: "flocked",
                        lexicalEntries: [
                            Self.makeLexicalEntry(
                                partOfSpeech: .noun,
                                label: "noun",
                                definition: "incorrect standalone hit",
                                inflections: []
                            )
                        ]
                    )
                default:
                    throw LookupError.notFound
                }
            }
        )

        let resolved = try await service.resolve("flocked", dictionaryName: "")

        XCTAssertEqual(resolved.word, "flock")
        XCTAssertEqual(resolved.sourceForm, "flocked")
        XCTAssertEqual(resolved.inflectionKind, .pastOrPastParticiple)
        XCTAssertEqual(resolved.expectedPartOfSpeech, .verb)
        XCTAssertEqual(resolved.lookupResult.entries.first?.lexicalEntries.first?.partOfSpeech, .verb)
    }

    func testResolvePluralKeepsLemmaAndPrioritizesNounEntry() async throws {
        let service = ResolvedLookupService(
            lookup: { term, _ in
                switch term {
                case "dog":
                    return Self.makeLookupResult(
                        query: "dog",
                        headword: "dog",
                        lexicalEntries: [
                            Self.makeLexicalEntry(
                                partOfSpeech: .verb,
                                label: "verb",
                                definition: "to follow persistently",
                                inflections: ["dogs"]
                            ),
                            Self.makeLexicalEntry(
                                partOfSpeech: .noun,
                                label: "noun",
                                definition: "a domesticated canine",
                                inflections: ["dogs"]
                            ),
                        ]
                    )
                default:
                    throw LookupError.notFound
                }
            }
        )

        let resolved = try await service.resolve("dogs", dictionaryName: "")

        XCTAssertEqual(resolved.word, "dog")
        XCTAssertEqual(resolved.sourceForm, "dogs")
        XCTAssertEqual(resolved.inflectionKind, .plural)
        XCTAssertEqual(resolved.expectedPartOfSpeech, .noun)
        XCTAssertEqual(resolved.lookupResult.entries.first?.lexicalEntries.first?.partOfSpeech, .noun)
    }

    func testResolveIrregularComparativeToGood() async throws {
        let service = ResolvedLookupService(
            lookup: { term, _ in
                switch term {
                case "good":
                    return Self.makeLookupResult(
                        query: "good",
                        headword: "good",
                        lexicalEntries: [
                            Self.makeLexicalEntry(
                                partOfSpeech: .adjective,
                                label: "adjective",
                                definition: "to be desired",
                                inflections: ["better", "best"]
                            )
                        ]
                    )
                case "better":
                    return Self.makeLookupResult(
                        query: "better",
                        headword: "better",
                        lexicalEntries: [
                            Self.makeLexicalEntry(
                                partOfSpeech: .adverb,
                                label: "adverb",
                                definition: "in a better way",
                                inflections: []
                            )
                        ]
                    )
                default:
                    throw LookupError.notFound
                }
            }
        )

        let resolved = try await service.resolve("better", dictionaryName: "")

        XCTAssertEqual(resolved.word, "good")
        XCTAssertEqual(resolved.sourceForm, "better")
        XCTAssertEqual(resolved.inflectionKind, .comparative)
        XCTAssertEqual(resolved.expectedPartOfSpeech, .adjective)
    }

    private static func makeLookupResult(
        query: String,
        headword: String,
        lexicalEntries: [LexicalEntry]
    ) -> LookupResult {
        LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: headword,
                    pronunciations: [Pronunciation(dialect: "AmE", ipa: "ipa", respelling: nil)],
                    lexicalEntries: lexicalEntries.enumerated().map { index, entry in
                        LexicalEntry(
                            partOfSpeech: entry.partOfSpeech,
                            partOfSpeechLabel: entry.partOfSpeechLabel,
                            displayIndex: index,
                            pronunciations: entry.pronunciations,
                            senses: entry.senses,
                            grammar: entry.grammar,
                            inflections: entry.inflections
                        )
                    },
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }

    private static func makeLexicalEntry(
        partOfSpeech: PartOfSpeech,
        label: String,
        definition: String,
        inflections: [String]
    ) -> LexicalEntry {
        LexicalEntry(
            partOfSpeech: partOfSpeech,
            partOfSpeechLabel: label,
            displayIndex: 0,
            pronunciations: [Pronunciation(dialect: "AmE", ipa: "ipa", respelling: nil)],
            senses: [
                Sense(
                    number: 1,
                    semanticHint: nil,
                    definition: definition,
                    examples: [],
                    registers: [],
                    countability: nil
                )
            ],
            grammar: [],
            inflections: inflections
        )
    }
}
