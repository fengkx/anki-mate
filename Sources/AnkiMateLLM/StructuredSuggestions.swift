import Foundation

public struct LLMAnchorSnapshot: Codable, Equatable, Sendable {
    public let text: String
    public let note: String?

    public init(text: String, note: String? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum LLMRecallCardMode: String, Codable, CaseIterable, Sendable {
    case fullSpelling = "full_spelling"
    case targetedLetterCloze = "targeted_letter_cloze"
    case phraseRecall = "phrase_recall"

    public var displayName: String {
        switch self {
        case .fullSpelling:
            return "Full Spelling"
        case .targetedLetterCloze:
            return "Targeted Letter Cloze"
        case .phraseRecall:
            return "Phrase Recall"
        }
    }
}

public struct LLMRecallCardDraft: Codable, Equatable, Sendable {
    public let mode: LLMRecallCardMode
    public let front: String
    public let back: String
    public let hint: String?
    public let anchor: LLMAnchorSnapshot?

    public init(
        mode: LLMRecallCardMode,
        front: String,
        back: String,
        hint: String? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) {
        self.mode = mode
        self.front = front.trimmingCharacters(in: .whitespacesAndNewlines)
        self.back = back.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hint = hint?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anchor = anchor
    }
}

public struct LLMPitfall: Codable, Equatable, Sendable {
    public let summary: String
    public let details: String?
    public let anchor: LLMAnchorSnapshot?

    public init(
        summary: String,
        details: String? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) {
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anchor = anchor
    }
}

public struct LLMMnemonic: Codable, Equatable, Sendable {
    public let clue: String
    public let anchor: LLMAnchorSnapshot?

    public init(clue: String, anchor: LLMAnchorSnapshot? = nil) {
        self.clue = clue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anchor = anchor
    }
}

public struct LLMCollocation: Codable, Equatable, Sendable {
    public let phrase: String
    public let gloss: String?
    public let anchor: LLMAnchorSnapshot?

    public init(
        phrase: String,
        gloss: String? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) {
        self.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gloss = gloss?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anchor = anchor
    }
}

public struct LLMExampleSentence: Codable, Equatable, Sendable {
    public let english: String
    public let translation: String
    public let senseIndex: Int?

    public init(
        english: String,
        translation: String,
        senseIndex: Int? = nil
    ) {
        self.english = english.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senseIndex = senseIndex
    }
}

public struct LLMUsageHint: Codable, Equatable, Sendable {
    public let text: String
    public let translation: String
    public let kind: String?
    public let senseIndex: Int?

    public init(
        text: String,
        translation: String,
        kind: String? = nil,
        senseIndex: Int? = nil
    ) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translation = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.senseIndex = senseIndex
    }
}

public struct LLMLearningAids: Codable, Equatable, Sendable {
    public let pitfalls: [LLMPitfall]
    public let mnemonics: [LLMMnemonic]
    public let collocations: [LLMCollocation]

    public init(
        pitfalls: [LLMPitfall] = [],
        mnemonics: [LLMMnemonic] = [],
        collocations: [LLMCollocation] = []
    ) {
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
    }
}
