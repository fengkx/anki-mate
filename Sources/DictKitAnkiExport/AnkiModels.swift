import Foundation

public struct AnkiDeckConfig: Sendable {
    public let deckId: Int64
    public let deckName: String
    public let deckDescription: String
    public let modelId: Int64

    public init(deckName: String = "DictKit Vocabulary", deckDescription: String = "") {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        self.deckId = now + Int64.random(in: 1...999)
        self.deckName = deckName
        self.deckDescription = deckDescription
        self.modelId = now + Int64.random(in: 1000...1999)
    }

    public init(deckId: Int64, deckName: String, deckDescription: String, modelId: Int64) {
        self.deckId = deckId
        self.deckName = deckName
        self.deckDescription = deckDescription
        self.modelId = modelId
    }
}

public struct AnkiNoteData: Sendable {
    public let word: String
    public let phonetic: String
    public let definitions: String
    public let audioFilename: String?
    public let audioData: Data?

    public init(
        word: String,
        phonetic: String,
        definitions: String,
        audioFilename: String?,
        audioData: Data?
    ) {
        self.word = word
        self.phonetic = phonetic
        self.definitions = definitions
        self.audioFilename = audioFilename
        self.audioData = audioData
    }

    /// Fields joined by unit separator (\x1f) for Anki's `flds` column.
    /// Order must match AnkiCardTemplate.fields: Word, Phonetic, Definitions, Audio
    var fieldsString: String {
        let audioRef = audioFilename.map { "[sound:\($0)]" } ?? ""
        return [word, phonetic, definitions, audioRef].joined(separator: "\u{1f}")
    }

    /// The sort field (first field = word)
    var sortField: String { word }
}

public struct AnkiDeckPayload: Sendable {
    public let deck: AnkiDeckConfig
    public let notes: [AnkiNoteData]

    public init(deck: AnkiDeckConfig, notes: [AnkiNoteData]) {
        self.deck = deck
        self.notes = notes
    }
}
