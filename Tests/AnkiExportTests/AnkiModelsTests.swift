import DictKit
@testable import DictKitAnkiExport
import Foundation
import XCTest

final class AnkiModelsTests: XCTestCase {
    func testFieldsStringFormat() {
        let note = AnkiNoteData(
            word: "apple",
            phonetic: "ˈæpəl",
            definitions: "<div>fruit</div>",
            audioFilename: "apple.wav",
            audioData: Data([0])
        )
        let fields = note.fieldsString
        let parts = fields.components(separatedBy: "\u{1f}")
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "apple")
        XCTAssertEqual(parts[1], "ˈæpəl")
        XCTAssertEqual(parts[2], "<div>fruit</div>")
        XCTAssertEqual(parts[3], "[sound:apple.wav]")
    }

    func testFieldsStringNoAudio() {
        let note = AnkiNoteData(
            word: "test",
            phonetic: "tɛst",
            definitions: "<div>exam</div>",
            audioFilename: nil,
            audioData: nil
        )
        let parts = note.fieldsString.components(separatedBy: "\u{1f}")
        XCTAssertEqual(parts[3], "")
    }

    func testSortField() {
        let note = AnkiNoteData(
            word: "hello",
            phonetic: "",
            definitions: "",
            audioFilename: nil,
            audioData: nil
        )
        XCTAssertEqual(note.sortField, "hello")
    }

    func testDeckConfigGeneratesUniqueIds() {
        let a = AnkiDeckConfig(deckName: "Test")
        let b = AnkiDeckConfig(deckName: "Test")
        // IDs are time-based with random offsets, very unlikely to collide
        XCTAssertNotEqual(a.deckId, b.deckId)
    }
}
