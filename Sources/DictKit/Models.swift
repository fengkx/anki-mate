import Foundation

public struct LookupResult: Codable, Equatable, Sendable {
    public let query: String
    public let entries: [HeadwordEntry]
    public let metadata: LookupMetadata
    public let source: SourcePayload?

    public init(
        query: String,
        entries: [HeadwordEntry],
        metadata: LookupMetadata,
        source: SourcePayload?
    ) {
        self.query = query
        self.entries = entries
        self.metadata = metadata
        self.source = source
    }
}

public struct LookupMetadata: Codable, Equatable, Sendable {
    public let usedSource: LookupSourceKind
    public let warnings: [String]

    public init(usedSource: LookupSourceKind, warnings: [String]) {
        self.usedSource = usedSource
        self.warnings = warnings
    }
}

public enum LookupSourceKind: String, Codable, Sendable {
    case publicAPI
    case privateHTML
}

public struct HeadwordEntry: Codable, Equatable, Sendable {
    public let headword: String
    public let pronunciations: [Pronunciation]
    public let lexicalEntries: [LexicalEntry]
    public let phraseGroups: [PhraseGroup]
    public let notes: [Note]

    public init(
        headword: String,
        pronunciations: [Pronunciation],
        lexicalEntries: [LexicalEntry],
        phraseGroups: [PhraseGroup],
        notes: [Note]
    ) {
        self.headword = headword
        self.pronunciations = pronunciations
        self.lexicalEntries = lexicalEntries
        self.phraseGroups = phraseGroups
        self.notes = notes
    }
}

public struct LexicalEntry: Codable, Equatable, Sendable {
    public let partOfSpeech: PartOfSpeech
    public let partOfSpeechLabel: String
    public let displayIndex: Int
    public let pronunciations: [Pronunciation]
    public let senses: [Sense]
    public let grammar: [String]
    public let inflections: [String]

    public init(
        partOfSpeech: PartOfSpeech,
        partOfSpeechLabel: String,
        displayIndex: Int,
        pronunciations: [Pronunciation],
        senses: [Sense],
        grammar: [String],
        inflections: [String]
    ) {
        self.partOfSpeech = partOfSpeech
        self.partOfSpeechLabel = partOfSpeechLabel
        self.displayIndex = displayIndex
        self.pronunciations = pronunciations
        self.senses = senses
        self.grammar = grammar
        self.inflections = inflections
    }
}

public struct Sense: Codable, Equatable, Sendable {
    public let number: Int
    public let semanticHint: String?
    public let definition: String
    public let examples: [String]
    public let registers: [String]
    public let countability: Countability?

    public init(
        number: Int,
        semanticHint: String?,
        definition: String,
        examples: [String],
        registers: [String],
        countability: Countability?
    ) {
        self.number = number
        self.semanticHint = semanticHint
        self.definition = definition
        self.examples = examples
        self.registers = registers
        self.countability = countability
    }
}

public struct PhraseGroup: Codable, Equatable, Sendable {
    public let title: String
    public let items: [PhraseItem]
    public let rawContent: String?

    public init(title: String, items: [PhraseItem], rawContent: String?) {
        self.title = title
        self.items = items
        self.rawContent = rawContent
    }
}

public struct PhraseItem: Codable, Equatable, Sendable {
    public let phrase: String
    public let definition: String?
    public let examples: [String]

    public init(phrase: String, definition: String?, examples: [String]) {
        self.phrase = phrase
        self.definition = definition
        self.examples = examples
    }
}

public struct Note: Codable, Equatable, Sendable {
    public let kind: NoteKind
    public let content: String

    public init(kind: NoteKind, content: String) {
        self.kind = kind
        self.content = content
    }
}

public enum NoteKind: String, Codable, Sendable {
    case etymology
    case usage
    case reference
}

public struct Pronunciation: Codable, Equatable, Sendable {
    public let dialect: String?
    public let ipa: String
    public let respelling: String?

    public init(dialect: String?, ipa: String, respelling: String?) {
        self.dialect = dialect
        self.ipa = ipa
        self.respelling = respelling
    }
}

public extension Pronunciation {
    var ttsIPANotation: String? {
        var normalized = ipa.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        // Reject respelling notation that was stored in the ipa field.
        // Respelling uses ASCII uppercase digraphs (SH, TH, CH, ZH) and
        // macron vowels (ē, ā, ī, ō, ū) which are not valid IPA.
        // Real IPA uses Unicode symbols like ʃ, θ, ð, tʃ, etc.
        guard !Self.isRespelling(normalized) else { return nil }
        // Strip parentheses used in dictionary IPA to mark optional sounds
        // (e.g. "ˈæp(ə)l" → "ˈæpəl"), as AVSpeechSynthesizer does not
        // understand this notation and falls back to spelling out the text.
        normalized = normalized.replacingOccurrences(of: "(", with: "")
        normalized = normalized.replacingOccurrences(of: ")", with: "")
        return normalized.isEmpty ? nil : normalized
    }

    /// Detects respelling notation by checking for ASCII uppercase letters,
    /// which appear in digraphs like SH, TH, CH but never in real IPA.
    private static func isRespelling(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value >= 0x41 && scalar.value <= 0x5A // A-Z
        }
    }

    var defaultSpeechLanguageCode: String? {
        switch dialect?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ame", "us", "american english":
            return "en-US"
        case "bre", "uk", "british english":
            return "en-GB"
        default:
            return nil
        }
    }
}

public enum PartOfSpeech: String, Codable, Sendable {
    case noun
    case verb
    case adjective
    case adverb
    case pronoun
    case determiner
    case preposition
    case conjunction
    case interjection
    case article
    case abbreviation
    case other
}

public enum Countability: String, Codable, Sendable {
    case countable
    case uncountable
    case countableAndUncountable
}

public struct SourcePayload: Codable, Equatable, Sendable {
    public let rawText: String?
    public let rawHTML: String?

    public init(rawText: String?, rawHTML: String?) {
        self.rawText = rawText
        self.rawHTML = rawHTML
    }
}

public enum LookupError: Error, Sendable, Equatable {
    case notFound
    case dictionaryUnavailable(String)
    case sourceUnavailable
    case parseFailed
}
