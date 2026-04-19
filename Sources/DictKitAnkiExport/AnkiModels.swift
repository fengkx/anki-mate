import Foundation

public enum AnkiNoteKind: Sendable, Equatable {
    case standard
    case recall
}

public struct AnkiDeckConfig: Sendable {
    public let deckId: Int64
    public let deckName: String
    public let deckDescription: String
    public let modelId: Int64
    public let recallModelId: Int64

    public init(deckName: String = AnkiExportIdentity.defaultDeckName, deckDescription: String = "") {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        self.deckId = now + Int64.random(in: 1...999)
        self.deckName = deckName
        self.deckDescription = deckDescription
        self.modelId = now + Int64.random(in: 1000...1999)
        self.recallModelId = now + Int64.random(in: 2000...2999)
    }

    public init(
        deckId: Int64,
        deckName: String,
        deckDescription: String,
        modelId: Int64,
        recallModelId: Int64? = nil
    ) {
        self.deckId = deckId
        self.deckName = deckName
        self.deckDescription = deckDescription
        self.modelId = modelId
        self.recallModelId = recallModelId ?? (modelId + 1_000_000)
    }
}

public struct AnkiNoteData: Sendable {
    public let kind: AnkiNoteKind
    public let word: String
    public let phonetic: String
    public let definitions: String
    public let audioFilename: String?
    public let audioData: Data?
    public let sortField: String
    public let fieldValues: [String]
    private let explicitGUIDSeed: String?

    public init(
        word: String,
        phonetic: String,
        definitions: String,
        audioFilename: String?,
        audioData: Data?,
        sortField: String? = nil,
        guidSeed: String? = nil
    ) {
        let audioRef = audioFilename.map { "[sound:\($0)]" } ?? ""
        self.kind = .standard
        self.word = word
        self.phonetic = phonetic
        self.definitions = definitions
        self.audioFilename = audioFilename
        self.audioData = audioData
        self.sortField = sortField ?? word
        self.fieldValues = [word, phonetic, definitions, audioRef]
        self.explicitGUIDSeed = guidSeed
    }

    public init(
        recallPrompt: String,
        recallMode: String,
        recallInstruction: String,
        recallHint: String,
        recallAnswerHTML: String,
        sourceWord: String,
        phonetic: String,
        definitionsHTML: String,
        audioFilename: String?,
        audioData: Data?,
        sortField: String,
        guidSeed: String
    ) {
        let audioRef = audioFilename.map { "[sound:\($0)]" } ?? ""
        self.kind = .recall
        self.word = recallPrompt
        self.phonetic = recallMode
        self.definitions = recallAnswerHTML
        self.audioFilename = audioFilename
        self.audioData = audioData
        self.sortField = sortField
        self.fieldValues = [
            recallPrompt,
            recallMode,
            recallInstruction,
            recallHint,
            recallAnswerHTML,
            sourceWord,
            phonetic,
            definitionsHTML,
            audioRef
        ]
        self.explicitGUIDSeed = guidSeed
    }

    /// Fields joined by unit separator (\x1f) for Anki's `flds` column.
    /// Order must match the selected note model field order.
    var fieldsString: String {
        fieldValues.joined(separator: "\u{1f}")
    }

    /// Keep the note identity stable so Anki can update an existing note on re-import.
    /// We intentionally key this off the normalized headword instead of mutable card content.
    var guidSeed: String {
        if let explicitGUIDSeed {
            return explicitGUIDSeed
        }
        return word
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    func fieldValue(at index: Int) -> String {
        guard fieldValues.indices.contains(index) else { return "" }
        return fieldValues[index]
    }
}

public struct AnkiDeckPayload: Sendable {
    public let deck: AnkiDeckConfig
    public let notes: [AnkiNoteData]

    public init(deck: AnkiDeckConfig, notes: [AnkiNoteData]) {
        self.deck = deck
        self.notes = notes
    }
}
