import DictKit
@testable import DictKitAnkiExport
import Foundation
import XCTest

/// Byte-level wireframe tests. These lock the concrete wireframe strings down
/// so a regression in spacing, borders, truncation, or section ordering fails
/// loudly. The Agent's ability to reason about the card depends on these
/// outputs being predictable.
final class CardWireframeRendererTests: XCTestCase {
    func testEmptyCardWireframeIsStableByteForByte() {
        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "apple",
            lookupResult: singleSenseLookup(
                word: "apple",
                pos: "noun",
                definition: "a round fruit with red or green skin",
                examples: []
            ),
            aiArtifacts: .empty
        )

        let expected = """
        ┌── FRONT ─────────────────────────────────────────┐
        │ apple                                            │
        └──────────────────────────────────────────────────┘
        ┌── BACK ──────────────────────────────────────────┐
        │ [noun]                                           │
        │   1. a round fruit with red or green skin        │
        └──────────────────────────────────────────────────┘
        """

        XCTAssertEqual(snapshot.wireframe, expected)
    }

    func testFullArtifactsWireframeRendersAllSectionsInCanonicalOrder() {
        let lookup = singleSenseLookup(
            word: "apple",
            pos: "noun",
            definition: "a round fruit",
            examples: ["She packed an apple in his lunch."]
        )

        let artifacts = AIArtifacts(
            exampleSentences: .init(accepted: [
                ExampleSentenceArtifact(text: "Apple Inc. released a new model. — 苹果公司发布了新款。")
            ]),
            definitionNote: .init(accepted: DefinitionNoteArtifact(
                text: "Usually the fruit; capital-A Apple refers to the company."
            )),
            pitfalls: .init(accepted: [PitfallArtifact(text: "Don't confuse with pineapple.")]),
            mnemonics: .init(accepted: [MnemonicArtifact(text: "An apple a day keeps the doctor away.")]),
            collocations: .init(accepted: [CollocationArtifact(phrase: "apple of my eye", note: "favorite person")])
        )

        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "apple",
            lookupResult: lookup,
            aiArtifacts: artifacts
        )
        let wireframe = snapshot.wireframe

        // Verify section ordering by locating header strings left-to-right
        // within the wireframe text.
        let order: [String] = [
            "[AI · usage cue]",
            "[AI · examples]",
            "[AI · pitfalls]",
            "[AI · mnemonics]",
            "[AI · collocations]"
        ]
        var lastIndex = wireframe.startIndex
        for header in order {
            guard let range = wireframe.range(of: header, range: lastIndex..<wireframe.endIndex) else {
                return XCTFail("Missing wireframe header: \(header)")
            }
            lastIndex = range.upperBound
        }

        // Spot-check line widths. Every framed line should reach exactly the
        // fixed outer width.
        let lines = wireframe.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines where line.hasPrefix("│") {
            XCTAssertEqual(
                visualWidth(of: line),
                WireframeLayout.contentWidth + 2,
                "Framed line width mismatch: '\(line)'"
            )
        }
    }

    func testBulletCollapsingAddsCollapsedSummary() {
        let pitfalls = (1...5).map { PitfallArtifact(text: "pitfall \($0)") }
        let artifacts = AIArtifacts(pitfalls: .init(accepted: pitfalls))
        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "apple",
            lookupResult: singleSenseLookup(word: "apple", pos: "noun", definition: "fruit", examples: []),
            aiArtifacts: artifacts
        )

        XCTAssertTrue(snapshot.wireframe.contains("[AI · pitfalls] (5 items)"))
        XCTAssertTrue(snapshot.wireframe.contains("pitfall 1"))
        XCTAssertTrue(snapshot.wireframe.contains("pitfall 2"))
        XCTAssertTrue(snapshot.wireframe.contains("pitfall 3"))
        XCTAssertFalse(snapshot.wireframe.contains("pitfall 4"))
        XCTAssertTrue(snapshot.wireframe.contains("(2 more, collapsed)"))
    }

    func testLongDefinitionIsTruncatedWithEllipsis() {
        let longDefinition = String(repeating: "a very long definition clause that keeps going ", count: 10)
        let lookup = singleSenseLookup(word: "verbose", pos: "adj", definition: longDefinition, examples: [])
        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "verbose",
            lookupResult: lookup,
            aiArtifacts: .empty
        )

        // The definition wraps; the truncation cap is 3 lines per sense, so
        // somewhere in the wireframe we should see an ellipsis on the sense
        // block.
        XCTAssertTrue(snapshot.wireframe.contains("…"), "Wireframe should truncate overflowing sense text with an ellipsis.")
    }

    func testEmptyCardShowsEmptyBackMarker() {
        // No senses, no artifacts: the back block should still render and say
        // it's empty so Agent knows there's nothing there yet.
        let lookup = LookupResult(
            query: "newword",
            entries: [
                HeadwordEntry(
                    headword: "newword",
                    pronunciations: [],
                    lexicalEntries: [],
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
        let snapshot = CardRenderSnapshotBuilder.standard(
            word: "newword",
            lookupResult: lookup,
            aiArtifacts: .empty
        )
        XCTAssertTrue(snapshot.wireframe.contains("(empty)"))
    }

    func testSectionOrderMatchesAnkiFieldFormatterSupplement() {
        // Canonical order agreed with AnkiFieldFormatter.aiSupplementHTML:
        // usageCue -> examples -> learning aids (pitfalls -> mnemonics -> collocations)
        XCTAssertEqual(
            CardRenderSnapshotBuilder.canonicalAISectionOrder,
            [.usageCue, .examples, .pitfalls, .mnemonics, .collocations]
        )
    }

    // MARK: - Helpers

    private func singleSenseLookup(
        word: String,
        pos: String,
        definition: String,
        examples: [String]
    ) -> LookupResult {
        LookupResult(
            query: word,
            entries: [
                HeadwordEntry(
                    headword: word,
                    pronunciations: [],
                    lexicalEntries: [
                        LexicalEntry(
                            partOfSpeech: PartOfSpeech(rawValue: pos) ?? .other,
                            partOfSpeechLabel: pos,
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
                    phraseGroups: [],
                    notes: []
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }

    /// Mirror of the internal `WireframeMetrics.visualWidth(of:)` so this
    /// test can assert on rendered line widths without importing private
    /// API. Only the subset of Unicode ranges we actually render is covered.
    private func visualWidth(of string: String) -> Int {
        var total = 0
        for scalar in string.unicodeScalars {
            let value = scalar.value
            if value < 0x20 || (value >= 0x7F && value < 0xA0) { continue }
            if value == 0x200B || value == 0x200C || value == 0x200D || value == 0xFEFF { continue }
            if (0x0300...0x036F).contains(value) { continue }
            total += isWide(value) ? 2 : 1
        }
        return total
    }

    private func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F: return true
        case 0x2E80...0x303E: return true
        case 0x3041...0x33FF: return true
        case 0x3400...0x4DBF: return true
        case 0x4E00...0x9FFF: return true
        case 0xA000...0xA4CF: return true
        case 0xAC00...0xD7A3: return true
        case 0xF900...0xFAFF: return true
        case 0xFE30...0xFE4F: return true
        case 0xFF00...0xFF60: return true
        case 0xFFE0...0xFFE6: return true
        case 0x1F300...0x1F64F: return true
        case 0x1F680...0x1F6FF: return true
        case 0x1F900...0x1F9FF: return true
        case 0x20000...0x2FFFD: return true
        default: return false
        }
    }
}
