import DictKit
import DictKitAnkiExport
import Foundation
import SQLite3
import XCTest

final class AnkiPackageWriterTests: XCTestCase {
    func testWriteCreatesApkgFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("test.apkg")
        let deck = AnkiDeckConfig(deckName: "Test Deck")
        let notes = [
            AnkiNoteData(
                word: "hello",
                phonetic: "həˈloʊ",
                definitions: "<div>greeting</div>",
                audioFilename: "hello.wav",
                audioData: Data(repeating: 0xAB, count: 44)
            )
        ]

        try AnkiPackageWriter.write(deck: deck, notes: notes, to: outputURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        // .apkg is a zip file - verify it starts with PK magic bytes
        let data = try Data(contentsOf: outputURL)
        XCTAssertGreaterThan(data.count, 0)
        XCTAssertEqual(data[0], 0x50) // 'P'
        XCTAssertEqual(data[1], 0x4B) // 'K'
    }

    func testSQLiteWriterKeepsGUIDStableForSameWordAcrossExports() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let deck = AnkiDeckConfig(deckId: 1, deckName: "Test Deck", deckDescription: "", modelId: 1)
        let firstPath = tempDir.appendingPathComponent("first.anki2").path
        let secondPath = tempDir.appendingPathComponent("second.anki2").path

        try AnkiSQLiteWriter.write(
            deck: deck,
            notes: [
                AnkiNoteData(
                    word: "lemmatize",
                    phonetic: "/ˈlemətaɪz/",
                    definitions: "<div>first export</div>",
                    audioFilename: nil,
                    audioData: nil
                )
            ],
            to: firstPath
        )
        try AnkiSQLiteWriter.write(
            deck: deck,
            notes: [
                AnkiNoteData(
                    word: "lemmatize",
                    phonetic: "/ˈlemətaɪz/",
                    definitions: "<div>second export with updated content</div>",
                    audioFilename: nil,
                    audioData: nil
                )
            ],
            to: secondPath
        )

        // Re-exporting the same headword with updated card content should preserve
        // the GUID so Anki can treat the import as an update instead of a new note.
        XCTAssertEqual(try noteGUIDs(at: firstPath), try noteGUIDs(at: secondPath))
    }

    func testSQLiteWriterUsesDifferentGUIDsForDifferentWords() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = tempDir.appendingPathComponent("notes.anki2").path
        let deck = AnkiDeckConfig(deckId: 1, deckName: "Test Deck", deckDescription: "", modelId: 1)

        try AnkiSQLiteWriter.write(
            deck: deck,
            notes: [
                AnkiNoteData(word: "lemmatize", phonetic: "", definitions: "<div>verb</div>", audioFilename: nil, audioData: nil),
                AnkiNoteData(word: "tokenize", phonetic: "", definitions: "<div>verb</div>", audioFilename: nil, audioData: nil)
            ],
            to: path
        )

        let guids = try noteGUIDs(at: path)
        XCTAssertEqual(guids.count, 2)
        XCTAssertEqual(Set(guids).count, 2)
    }

    func testSQLiteWriterUsesNeutralExportMetadata() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let path = tempDir.appendingPathComponent("branding.anki2").path
        try AnkiSQLiteWriter.write(
            deck: AnkiDeckConfig(),
            notes: [
                AnkiNoteData(word: "brand", phonetic: "", definitions: "<div>test</div>", audioFilename: nil, audioData: nil)
            ],
            to: path
        )

        let collectionRow = try collectionRow(at: path)
        XCTAssertTrue(collectionRow.models.contains("\"name\":\"Basic\""))
        XCTAssertTrue(collectionRow.models.contains("\"name\":\"Recall\""))
        XCTAssertTrue(collectionRow.decks.contains("\"name\":\"Vocabulary\""))
        XCTAssertFalse(collectionRow.models.localizedCaseInsensitiveContains("anki mate"))
        XCTAssertFalse(collectionRow.decks.localizedCaseInsensitiveContains("anki mate"))
        XCTAssertFalse(collectionRow.models.localizedCaseInsensitiveContains("dictkit"))
        XCTAssertFalse(collectionRow.decks.localizedCaseInsensitiveContains("dictkit"))
    }

    private func noteGUIDs(at path: String) throws -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = "SELECT guid FROM notes ORDER BY sfld ASC"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                values.append(String(cString: text))
            }
        }
        return values
    }

    private func collectionRow(at path: String) throws -> (models: String, decks: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        let sql = "SELECT models, decks FROM col LIMIT 1"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        let models = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let decks = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        return (models, decks)
    }
}

final class AnkiExporterTests: XCTestCase {
    func testExportEndToEnd() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("vocab.apkg")
        let lookupResult = LookupResult(
            query: "apple",
            entries: [HeadwordEntry(
                headword: "apple",
                pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)],
                lexicalEntries: [LexicalEntry(
                    partOfSpeech: .noun,
                    partOfSpeechLabel: "noun",
                    displayIndex: 0,
                    pronunciations: [],
                    senses: [Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: "the round fruit of a tree of the rose family",
                        examples: ["I had an apple for lunch"],
                        registers: [],
                        countability: .countable
                    )],
                    grammar: [],
                    inflections: ["apples"]
                )],
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )

        let inputs = [
            AnkiExporter.ExportInput(
                word: "apple",
                lookupResult: lookupResult,
                audioData: Data(repeating: 0xFF, count: 100)
            )
        ]

        let result = try AnkiExporter.export(words: inputs, deckName: "Test", to: outputURL)
        XCTAssertEqual(result.cardCount, 1)
        XCTAssertEqual(result.mediaCount, 1)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testExportWithoutAudio() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("no_audio.apkg")
        let lookupResult = LookupResult(
            query: "test",
            entries: [HeadwordEntry(
                headword: "test",
                pronunciations: [],
                lexicalEntries: [LexicalEntry(
                    partOfSpeech: .noun,
                    partOfSpeechLabel: "noun",
                    displayIndex: 0,
                    pronunciations: [],
                    senses: [Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: "a procedure to establish quality",
                        examples: [],
                        registers: [],
                        countability: nil
                    )],
                    grammar: [],
                    inflections: []
                )],
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )

        let inputs = [
            AnkiExporter.ExportInput(word: "test", lookupResult: lookupResult, audioData: nil)
        ]

        let result = try AnkiExporter.export(words: inputs, deckName: "Test", to: outputURL)
        XCTAssertEqual(result.cardCount, 1)
        XCTAssertEqual(result.mediaCount, 0)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("No pronunciation") }))
    }

    func testExportSupportsMultipleDecks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("multi.apkg")
        let lookupResult = LookupResult(
            query: "apple",
            entries: [HeadwordEntry(
                headword: "apple",
                pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)],
                lexicalEntries: [LexicalEntry(
                    partOfSpeech: .noun,
                    partOfSpeechLabel: "noun",
                    displayIndex: 0,
                    pronunciations: [],
                    senses: [Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: "the round fruit of a tree of the rose family",
                        examples: ["I had an apple for lunch"],
                        registers: [],
                        countability: .countable
                    )],
                    grammar: [],
                    inflections: ["apples"]
                )],
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )

        let result = try AnkiExporter.export(
            decks: [
                AnkiExporter.ExportDeck(
                    deckName: "Deck A",
                    words: [
                        AnkiExporter.ExportInput(word: "apple", lookupResult: lookupResult, audioData: Data([0x01]))
                    ]
                ),
                AnkiExporter.ExportDeck(
                    deckName: "Deck B",
                    words: [
                        AnkiExporter.ExportInput(word: "apple", lookupResult: lookupResult, audioData: Data([0x01]))
                    ]
                )
            ],
            to: outputURL
        )

        XCTAssertEqual(result.cardCount, 2)
        XCTAssertEqual(result.mediaCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testAIArtifactsExportAcceptsUnifiedContract() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("artifacts.apkg")
        let lookupResult = LookupResult(
            query: "consensus",
            entries: [HeadwordEntry(
                headword: "consensus",
                pronunciations: [Pronunciation(dialect: "AmE", ipa: "kənˈsɛnsəs", respelling: nil)],
                lexicalEntries: [LexicalEntry(
                    partOfSpeech: .noun,
                    partOfSpeechLabel: "noun",
                    displayIndex: 0,
                    pronunciations: [],
                    senses: [Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: "general agreement",
                        examples: [],
                        registers: [],
                        countability: nil
                    )],
                    grammar: [],
                    inflections: []
                )],
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )

        let artifacts = AIArtifacts(
            definitionNote: AIArtifactSlot(
                accepted: DefinitionNoteArtifact(text: "Use it for group agreement, not individual permission.")
            ),
            recallCardDrafts: AIArtifactSlot(
                accepted: [RecallCardDraft(mode: .phraseRecall, front: "reach a ____", back: "consensus")]
            ),
            pitfalls: AIArtifactSlot(
                accepted: [PitfallArtifact(text: "Do not confuse it with consent.")]
            ),
            collocations: AIArtifactSlot(
                accepted: [CollocationArtifact(phrase: "reach a consensus")]
            )
        )

        let result = try AnkiExporter.export(
            words: [
                AnkiExporter.ExportInput(
                    word: "consensus",
                    lookupResult: lookupResult,
                    audioData: nil,
                    aiArtifacts: artifacts
                )
            ],
            deckName: "Artifacts",
            to: outputURL
        )

        XCTAssertEqual(result.cardCount, 2)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testAIArtifactsExportKeepsOnlyOneAcceptedRecallCard() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("single_recall.apkg")
        let lookupResult = LookupResult(
            query: "consensus",
            entries: [HeadwordEntry(
                headword: "consensus",
                pronunciations: [Pronunciation(dialect: "AmE", ipa: "kənˈsɛnsəs", respelling: nil)],
                lexicalEntries: [LexicalEntry(
                    partOfSpeech: .noun,
                    partOfSpeechLabel: "noun",
                    displayIndex: 0,
                    pronunciations: [],
                    senses: [Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: "general agreement",
                        examples: [],
                        registers: [],
                        countability: nil
                    )],
                    grammar: [],
                    inflections: []
                )],
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )

        let artifacts = AIArtifacts(
            recallCardDrafts: AIArtifactSlot(
                accepted: [
                    RecallCardDraft(mode: .phraseRecall, front: "first prompt", back: "first answer"),
                    RecallCardDraft(mode: .fullSpelling, front: "second prompt", back: "second answer")
                ]
            )
        )

        let result = try AnkiExporter.export(
            words: [
                AnkiExporter.ExportInput(
                    word: "consensus",
                    lookupResult: lookupResult,
                    audioData: nil,
                    aiArtifacts: artifacts
                )
            ],
            deckName: "Artifacts",
            to: outputURL
        )

        XCTAssertEqual(result.cardCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testAIArtifactsExportPassesUnifiedSectionsIntoCardHTML() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("render.apkg")
        let lookupResult = LookupResult(
            query: "consensus",
            entries: [HeadwordEntry(
                headword: "consensus",
                pronunciations: [Pronunciation(dialect: "AmE", ipa: "kənˈsɛnsəs", respelling: nil)],
                lexicalEntries: [LexicalEntry(
                    partOfSpeech: .noun,
                    partOfSpeechLabel: "noun",
                    displayIndex: 0,
                    pronunciations: [],
                    senses: [Sense(
                        number: 1,
                        semanticHint: nil,
                        definition: "general agreement",
                        examples: [],
                        registers: [],
                        countability: nil
                    )],
                    grammar: [],
                    inflections: []
                )],
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )

        let artifacts = AIArtifacts(
            recallCardDrafts: AIArtifactSlot(
                accepted: [
                    RecallCardDraft(mode: .phraseRecall, front: "The committee reached a ____.", back: "consensus", hint: "noun")
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
            )
        )

        let result = try AnkiExporter.export(
            words: [
                AnkiExporter.ExportInput(
                    word: "consensus",
                    lookupResult: lookupResult,
                    audioData: nil,
                    aiArtifacts: artifacts
                )
            ],
            deckName: "Artifacts",
            to: outputURL
        )

        XCTAssertEqual(result.cardCount, 2)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }
}
