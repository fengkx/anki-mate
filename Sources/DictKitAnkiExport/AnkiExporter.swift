import DictKit
import Foundation

public struct AnkiExporter: Sendable {
    public struct ExportInput: Sendable {
        public let word: String
        public let lookupResult: LookupResult
        public let audioData: Data?
        public let aiArtifacts: AIArtifacts

        public init(
            word: String,
            lookupResult: LookupResult,
            audioData: Data?,
            aiArtifacts: AIArtifacts = .empty,
            aiAcceptedExampleSentences: [String] = [],
            aiAcceptedDefinitionNote: String? = nil,
            aiAcceptedRecallCardDrafts: [RecallCardDraft] = [],
            aiAcceptedPitfalls: [String] = [],
            aiAcceptedMnemonics: [String] = [],
            aiAcceptedCollocations: [String] = []
        ) {
            self.word = word
            self.lookupResult = lookupResult
            self.audioData = audioData
            self.aiArtifacts = aiArtifacts.fillingMissingSlots(
                legacyAcceptedExampleSentences: aiAcceptedExampleSentences,
                legacyAcceptedDefinitionNote: aiAcceptedDefinitionNote,
                legacyAcceptedRecallCardDrafts: aiAcceptedRecallCardDrafts,
                legacyAcceptedPitfalls: aiAcceptedPitfalls,
                legacyAcceptedMnemonics: aiAcceptedMnemonics,
                legacyAcceptedCollocations: aiAcceptedCollocations
            ).normalized()
        }

        public var aiAcceptedExampleSentences: [String] { aiArtifacts.acceptedExampleSentences }
        public var aiAcceptedDefinitionNote: String? { aiArtifacts.acceptedDefinitionNoteText }
        public var aiAcceptedRecallCardDrafts: [RecallCardDraft] { aiArtifacts.recallCardDrafts.accepted ?? [] }
        public var aiAcceptedPitfalls: [String] { aiArtifacts.acceptedPitfallTexts }
        public var aiAcceptedMnemonics: [String] { aiArtifacts.acceptedMnemonicTexts }
        public var aiAcceptedCollocations: [String] { aiArtifacts.acceptedCollocationPhrases }
    }

    public struct ExportDeck: Sendable {
        public let deckName: String
        public let deckDescription: String
        public let words: [ExportInput]

        public init(deckName: String, deckDescription: String = "", words: [ExportInput]) {
            self.deckName = deckName
            self.deckDescription = deckDescription
            self.words = words
        }
    }

    public struct ExportResult: Sendable {
        public let outputURL: URL
        public let cardCount: Int
        public let mediaCount: Int
        public let warnings: [String]
    }

    public static func export(
        words: [ExportInput],
        deckName: String = "Anki Mate Vocabulary",
        to outputURL: URL
    ) throws -> ExportResult {
        try export(
            decks: [
                ExportDeck(deckName: deckName, words: words)
            ],
            to: outputURL
        )
    }

    public static func export(
        decks: [ExportDeck],
        to outputURL: URL
    ) throws -> ExportResult {
        let payloads = decks.map { deck in
            makeDeckPayload(deckName: deck.deckName, deckDescription: deck.deckDescription, words: deck.words)
        }
        var warnings: [String] = []
        let uniqueMediaNames = Set(
            payloads
                .flatMap(\.notes)
                .compactMap(\.audioFilename)
        )

        for deck in decks {
            for input in deck.words {
                let phonetic = AnkiFieldFormatter.phoneticDisplay(from: input.lookupResult)
                let definitions = AnkiFieldFormatter.definitionsHTML(
                    from: input.lookupResult,
                    aiArtifacts: input.aiArtifacts
                )
                if phonetic.isEmpty {
                    warnings.append("No pronunciation found for '\(input.word)'")
                }
                if definitions.isEmpty {
                    warnings.append("No definitions found for '\(input.word)'")
                }
            }
        }

        try AnkiPackageWriter.write(decks: payloads, to: outputURL)

        return ExportResult(
            outputURL: outputURL,
            cardCount: payloads.reduce(0) { $0 + $1.notes.count },
            mediaCount: uniqueMediaNames.count,
            warnings: warnings
        )
    }

    private static func makeDeckPayload(deckName: String, deckDescription: String, words: [ExportInput]) -> AnkiDeckPayload {
        let deck = AnkiDeckConfig(deckName: deckName, deckDescription: deckDescription)
        let notes = words.map { input in
            let phonetic = AnkiFieldFormatter.phoneticDisplay(from: input.lookupResult)
            let definitions = AnkiFieldFormatter.definitionsHTML(
                from: input.lookupResult,
                aiArtifacts: input.aiArtifacts
            )
            let audioFilename = input.audioData.map { _ in
                input.word
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "_")
                    .lowercased() + ".wav"
            }
            return AnkiNoteData(
                word: input.word,
                phonetic: phonetic,
                definitions: definitions,
                audioFilename: audioFilename,
                audioData: input.audioData
            )
        }
        return AnkiDeckPayload(deck: deck, notes: notes)
    }
}
