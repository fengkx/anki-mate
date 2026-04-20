import DictKit
import DictKitAnkiExport
import Foundation
import XCTest

/// Behavior-level tests for `CardRenderSnapshotBuilder`. These focus on the
/// contract callers rely on (what section is present, what kind of content
/// shows up where), while byte-level wireframe snapshots live in
/// `CardWireframeRendererTests`.
final class CardRenderSnapshotTests: XCTestCase {
    // MARK: - Standard

    func testStandardEmptyArtifactsOmitsAISections() {
        let result = makeLookup(
            word: "apple",
            senses: [("noun", "a round fruit", [])]
        )

        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "apple",
            lookupResult: result,
            aiArtifacts: .empty
        )

        XCTAssertEqual(snapshot.kind, .standard)
        XCTAssertEqual(snapshot.word, "apple")
        XCTAssertTrue(snapshot.aiSectionOrder.isEmpty, "Empty AI artifacts should produce no AI sections.")
        XCTAssertFalse(snapshot.wireframe.contains("[AI ·"))
        XCTAssertTrue(snapshot.wireframe.contains("[noun]"))
        XCTAssertTrue(snapshot.wireframe.contains("a round fruit"))
    }

    func testStandardFullArtifactsPreservesCanonicalSectionOrder() {
        let result = makeLookup(
            word: "apple",
            senses: [("noun", "a round fruit with red or green skin", ["She packed an apple."])]
        )

        let artifacts = AIArtifacts(
            exampleSentences: .init(accepted: [ExampleSentenceArtifact(text: "Apple Inc. released a new model. — 苹果公司发布了新款。")]),
            definitionNote: .init(accepted: DefinitionNoteArtifact(text: "Usually the fruit; capital-A Apple refers to the company.")),
            pitfalls: .init(accepted: [PitfallArtifact(text: "Don't confuse with pineapple.")]),
            mnemonics: .init(accepted: [MnemonicArtifact(text: "An apple a day…")]),
            collocations: .init(accepted: [CollocationArtifact(phrase: "apple of my eye")])
        )

        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "apple",
            lookupResult: result,
            aiArtifacts: artifacts
        )

        XCTAssertEqual(
            snapshot.aiSectionOrder,
            [.usageCue, .examples, .pitfalls, .mnemonics, .collocations],
            "AI section order must match AnkiFieldFormatter.aiSupplementHTML."
        )

        // Wireframe contains every section header in the canonical order.
        let usageRange = snapshot.wireframe.range(of: "[AI · usage cue]")
        let examplesRange = snapshot.wireframe.range(of: "[AI · examples]")
        let pitfallsRange = snapshot.wireframe.range(of: "[AI · pitfalls]")
        let mnemonicsRange = snapshot.wireframe.range(of: "[AI · mnemonics]")
        let collocationsRange = snapshot.wireframe.range(of: "[AI · collocations]")
        XCTAssertNotNil(usageRange)
        XCTAssertNotNil(examplesRange)
        XCTAssertNotNil(pitfallsRange)
        XCTAssertNotNil(mnemonicsRange)
        XCTAssertNotNil(collocationsRange)
        XCTAssertLessThan(usageRange!.lowerBound, examplesRange!.lowerBound)
        XCTAssertLessThan(examplesRange!.lowerBound, pitfallsRange!.lowerBound)
        XCTAssertLessThan(pitfallsRange!.lowerBound, mnemonicsRange!.lowerBound)
        XCTAssertLessThan(mnemonicsRange!.lowerBound, collocationsRange!.lowerBound)
    }

    func testStandardWireframeAndJSONStayInSyncOnAISections() {
        let result = makeLookup(
            word: "release",
            senses: [("verb", "allow or enable to escape", ["He released the brake."])]
        )

        let artifacts = AIArtifacts(
            exampleSentences: .init(accepted: [ExampleSentenceArtifact(text: "Release the software tomorrow.")]),
            definitionNote: .init(accepted: DefinitionNoteArtifact(text: "In product contexts: ship it to users.")),
            collocations: .init(accepted: [CollocationArtifact(phrase: "release date")])
        )

        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "release",
            lookupResult: result,
            aiArtifacts: artifacts
        )

        let json = snapshot.structuredJSON

        // The JSON always lists every artifact category, but some will be
        // empty. What we care about: every AI section shown in wireframe is
        // also populated in JSON, and vice versa.
        let wireframeSections = Set<String>(snapshot.aiSectionOrder.map { $0.rawValue })
        let expectedInWireframe: Set<String> = ["usageCue", "examples", "collocations"]
        XCTAssertEqual(wireframeSections, expectedInWireframe)

        XCTAssertTrue(json.contains("\"usageCue\""))
        XCTAssertTrue(json.contains("\"examples\""))
        XCTAssertTrue(json.contains("\"collocations\""))
        XCTAssertTrue(json.contains("\"pitfalls\":[]"), "Empty section should still be present as empty array for schema stability.")
        XCTAssertTrue(json.contains("\"mnemonics\":[]"))
    }

    func testStandardSenseIDsFollowStablePattern() {
        let result = LookupResult(
            query: "set",
            entries: [
                HeadwordEntry(
                    headword: "set",
                    pronunciations: [],
                    lexicalEntries: [
                        LexicalEntry(
                            partOfSpeech: .verb,
                            partOfSpeechLabel: "verb",
                            displayIndex: 0,
                            pronunciations: [],
                            senses: [
                                Sense(number: 1, semanticHint: nil, definition: "put in place", examples: [], registers: [], countability: nil),
                                Sense(number: 2, semanticHint: nil, definition: "cause to happen", examples: [], registers: [], countability: nil)
                            ],
                            grammar: [],
                            inflections: []
                        ),
                        LexicalEntry(
                            partOfSpeech: .noun,
                            partOfSpeechLabel: "noun",
                            displayIndex: 1,
                            pronunciations: [],
                            senses: [
                                Sense(number: 1, semanticHint: nil, definition: "a group of things", examples: [], registers: [], countability: nil)
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

        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "set",
            lookupResult: result,
            aiArtifacts: .empty
        )

        XCTAssertTrue(snapshot.structuredJSON.contains("\"id\":\"sense-0-0\""))
        XCTAssertTrue(snapshot.structuredJSON.contains("\"id\":\"sense-0-1\""))
        XCTAssertTrue(snapshot.structuredJSON.contains("\"id\":\"sense-1-0\""))
    }

    // MARK: - Recall

    func testRecallWithoutDraftShowsPlaceholder() {
        let result = makeLookup(word: "apple", senses: [("noun", "a round fruit", [])])

        let snapshot = CardRenderSnapshotBuilder.recall(
            word: "apple",
            lookupResult: result,
            aiArtifacts: .empty
        )

        XCTAssertEqual(snapshot.kind, .recall)
        XCTAssertTrue(snapshot.wireframe.contains("NO DRAFT"), "Missing recall draft should be obvious in wireframe.")
        XCTAssertTrue(snapshot.structuredJSON.contains("\"recall\""))
    }

    func testRecallWithDraftIncludesFrontBackAndHint() {
        let result = makeLookup(word: "apple", senses: [("noun", "a round fruit", [])])
        let draft = RecallCardDraft(
            mode: .phraseRecall,
            front: "她每天吃一个 ___ 来保持健康。",
            back: "apple",
            hint: "一种水果"
        )
        let artifacts = AIArtifacts(
            recallCardDrafts: .init(accepted: [draft])
        )

        let snapshot = CardRenderSnapshotBuilder.recall(
            word: "apple",
            lookupResult: result,
            aiArtifacts: artifacts
        )

        XCTAssertTrue(snapshot.wireframe.contains("她每天吃一个"))
        XCTAssertTrue(snapshot.wireframe.contains("hint: 一种水果"))
        XCTAssertTrue(snapshot.wireframe.contains("apple"))
        XCTAssertTrue(snapshot.wireframe.contains("[Source dictionary]"))
        XCTAssertTrue(snapshot.structuredJSON.contains("\"phrase_recall\""))
        XCTAssertTrue(snapshot.structuredJSON.contains("\"hint\":\"一种水果\""))
    }

    // MARK: - Helpers

    private func makeLookup(word: String, senses: [(String, String, [String])]) -> LookupResult {
        let lexEntries: [LexicalEntry] = senses.enumerated().map { index, tuple in
            LexicalEntry(
                partOfSpeech: PartOfSpeech(rawValue: tuple.0) ?? .other,
                partOfSpeechLabel: tuple.0,
                displayIndex: index,
                pronunciations: [],
                senses: [
                    Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: tuple.1,
                        examples: tuple.2,
                        registers: [],
                        countability: nil
                    )
                ],
                grammar: [],
                inflections: []
            )
        }
        return LookupResult(
            query: word,
            entries: [
                HeadwordEntry(
                    headword: word,
                    pronunciations: [],
                    lexicalEntries: lexEntries,
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }
}
