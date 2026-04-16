@testable import DictKitAnkiExport
import Foundation
import SQLite3
import XCTest

final class AnkiSQLiteWriterTests: XCTestCase {
    func testGUIDLength() {
        let guid = AnkiSQLiteWriter.ankiGUID()
        XCTAssertEqual(guid.count, 10)
    }

    func testGUIDUniqueness() {
        let guids = (0..<100).map { _ in AnkiSQLiteWriter.ankiGUID() }
        XCTAssertEqual(Set(guids).count, guids.count, "GUIDs should be unique")
    }

    func testFieldChecksum() {
        let csum = AnkiSQLiteWriter.fieldChecksum("apple")
        XCTAssertGreaterThan(csum, 0)
        // Same input should produce same checksum
        XCTAssertEqual(csum, AnkiSQLiteWriter.fieldChecksum("apple"))
        // Different input should produce different checksum
        XCTAssertNotEqual(csum, AnkiSQLiteWriter.fieldChecksum("banana"))
    }

    func testWriteCreatesDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("collection.anki2").path
        let deck = AnkiDeckConfig(deckName: "Test Deck")
        let notes = [
            AnkiNoteData(
                word: "hello",
                phonetic: "həˈloʊ",
                definitions: "<div>greeting</div>",
                audioFilename: "hello.wav",
                audioData: Data([0x00])
            ),
            AnkiNoteData(
                word: "world",
                phonetic: "wɜːrld",
                definitions: "<div>earth</div>",
                audioFilename: nil,
                audioData: nil
            )
        ]

        try AnkiSQLiteWriter.write(deck: deck, notes: notes, to: dbPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))

        // Verify file is a valid SQLite database (starts with "SQLite format 3")
        let data = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        XCTAssertGreaterThan(data.count, 100)
        let header = String(data: data.prefix(16), encoding: .utf8) ?? ""
        XCTAssertTrue(header.hasPrefix("SQLite format 3"), "Should be a valid SQLite file")
    }

    func testWriteSupportsMultipleDecksInSingleCollectionDatabase() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbPath = tempDir.appendingPathComponent("collection.anki2").path
        try AnkiSQLiteWriter.write(
            decks: [
                AnkiDeckPayload(
                    deck: AnkiDeckConfig(deckName: "Deck A"),
                    notes: [
                        AnkiNoteData(
                            word: "apple",
                            phonetic: "ˈæpəl",
                            definitions: "<div>fruit</div>",
                            audioFilename: "apple.wav",
                            audioData: Data([0x01])
                        )
                    ]
                ),
                AnkiDeckPayload(
                    deck: AnkiDeckConfig(deckName: "Deck B"),
                    notes: [
                        AnkiNoteData(
                            word: "apple",
                            phonetic: "ˈæpəl",
                            definitions: "<div>fruit</div>",
                            audioFilename: "apple.wav",
                            audioData: Data([0x01])
                        )
                    ]
                )
            ],
            to: dbPath
        )

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT decks FROM col", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let decksJSON = String(cString: sqlite3_column_text(stmt, 0))
        XCTAssertTrue(decksJSON.contains("Deck A"))
        XCTAssertTrue(decksJSON.contains("Deck B"))

        XCTAssertEqual(scalar(db: db, sql: "SELECT COUNT(*) FROM cards"), 2)
    }

    private func scalar(db: OpaquePointer?, sql: String) -> Int {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        defer { sqlite3_finalize(stmt) }
        sqlite3_step(stmt)
        return Int(sqlite3_column_int(stmt, 0))
    }
}
