import DictKit
import DictKitAnkiExport
import Foundation
import XCTest

final class AnkiFieldFormatterTests: XCTestCase {
    func testPhoneticExtraction() {
        let result = makeLookupResult(
            word: "apple",
            pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)]
        )
        XCTAssertEqual(AnkiFieldFormatter.phonetic(from: result), "ˈæpəl")
    }

    func testPhoneticFallsBackToLexicalEntry() {
        let result = makeLookupResult(
            word: "test",
            pronunciations: [],
            lexicalPronunciations: [Pronunciation(dialect: nil, ipa: "tɛst", respelling: nil)]
        )
        XCTAssertEqual(AnkiFieldFormatter.phonetic(from: result), "tɛst")
    }

    func testPhoneticReturnsEmptyWhenNone() {
        let result = makeLookupResult(word: "unknown", pronunciations: [])
        XCTAssertEqual(AnkiFieldFormatter.phonetic(from: result), "")
    }

    func testDefinitionsHTMLContainsPOS() {
        let result = makeLookupResult(
            word: "run",
            pronunciations: [],
            senses: [("verb", "move at a speed faster than a walk", ["she ran to the door"])]
        )
        let html = AnkiFieldFormatter.definitionsHTML(from: result)
        XCTAssertTrue(html.contains("verb"))
        XCTAssertTrue(html.contains("move at a speed faster than a walk"))
        XCTAssertTrue(html.contains("she ran to the door"))
    }

    func testDefinitionsHTMLEscapesSpecialChars() {
        let result = makeLookupResult(
            word: "test",
            pronunciations: [],
            senses: [("noun", "a <b>bold</b> & \"quoted\" definition", [])]
        )
        let html = AnkiFieldFormatter.definitionsHTML(from: result)
        XCTAssertTrue(html.contains("&lt;b&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;"))
    }

    func testRenderCardHTMLFront() {
        let note = AnkiNoteData(
            word: "apple",
            phonetic: "ˈæpəl",
            definitions: "<div>test</div>",
            audioFilename: nil,
            audioData: nil
        )
        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: false)
        XCTAssertTrue(html.contains("apple"))
        XCTAssertTrue(html.contains("ˈæpəl"))
        XCTAssertFalse(html.contains("<div>test</div>"))
    }

    func testRenderCardHTMLBack() {
        let note = AnkiNoteData(
            word: "apple",
            phonetic: "ˈæpəl",
            definitions: "<div>test</div>",
            audioFilename: nil,
            audioData: nil
        )
        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: true)
        XCTAssertTrue(html.contains("apple"))
        XCTAssertTrue(html.contains("<div>test</div>"))
        XCTAssertTrue(html.contains("hr id=\"answer\""))
    }

    // MARK: - Helpers

    private func makeLookupResult(
        word: String,
        pronunciations: [Pronunciation],
        lexicalPronunciations: [Pronunciation] = [],
        senses: [(String, String, [String])] = []
    ) -> LookupResult {
        let lexEntries: [LexicalEntry] = senses.isEmpty
            ? [LexicalEntry(
                partOfSpeech: .noun,
                partOfSpeechLabel: "noun",
                displayIndex: 0,
                pronunciations: lexicalPronunciations,
                senses: [Sense(number: 1, semanticHint: nil, definition: "test", examples: [], registers: [], countability: nil)],
                grammar: [],
                inflections: []
            )]
            : senses.enumerated().map { i, s in
                LexicalEntry(
                    partOfSpeech: PartOfSpeech(rawValue: s.0) ?? .other,
                    partOfSpeechLabel: s.0,
                    displayIndex: i,
                    pronunciations: lexicalPronunciations,
                    senses: [Sense(number: 1, semanticHint: nil, definition: s.1, examples: s.2, registers: [], countability: nil)],
                    grammar: [],
                    inflections: []
                )
            }

        return LookupResult(
            query: word,
            entries: [HeadwordEntry(
                headword: word,
                pronunciations: pronunciations,
                lexicalEntries: lexEntries,
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }
}
