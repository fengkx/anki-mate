import DictKit
import DictKitAnkiExport
import Foundation
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

    func testExportAcceptsUnifiedAIArtifactsContract() throws {
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

        XCTAssertEqual(result.cardCount, 1)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }
}
