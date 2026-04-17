import Foundation

public struct AIArtifactSlot<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var suggested: Value?
    public var accepted: Value?

    public init(suggested: Value? = nil, accepted: Value? = nil) {
        self.suggested = suggested
        self.accepted = accepted
    }
}

public struct AIArtifactAnchorSnapshot: Codable, Equatable, Sendable {
    public let headword: String?
    public let lexicalEntryIndex: Int?
    public let senseIndex: Int?
    public let exampleIndex: Int?
    public let excerpt: String?

    public init(
        headword: String? = nil,
        lexicalEntryIndex: Int? = nil,
        senseIndex: Int? = nil,
        exampleIndex: Int? = nil,
        excerpt: String? = nil
    ) {
        self.headword = headword
        self.lexicalEntryIndex = lexicalEntryIndex
        self.senseIndex = senseIndex
        self.exampleIndex = exampleIndex
        self.excerpt = excerpt
    }
}

public struct ExampleSentenceArtifact: Codable, Equatable, Sendable {
    public let text: String
    public let translation: String?
    public let note: String?
    public let anchor: AIArtifactAnchorSnapshot?

    public init(
        text: String,
        translation: String? = nil,
        note: String? = nil,
        anchor: AIArtifactAnchorSnapshot? = nil
    ) {
        self.text = text
        self.translation = translation
        self.note = note
        self.anchor = anchor
    }
}

public struct DefinitionNoteArtifact: Codable, Equatable, Sendable {
    public let text: String
    public let anchor: AIArtifactAnchorSnapshot?

    public init(text: String, anchor: AIArtifactAnchorSnapshot? = nil) {
        self.text = text
        self.anchor = anchor
    }
}

public struct PitfallArtifact: Codable, Equatable, Sendable {
    public let text: String
    public let anchor: AIArtifactAnchorSnapshot?

    public init(text: String, anchor: AIArtifactAnchorSnapshot? = nil) {
        self.text = text
        self.anchor = anchor
    }
}

public struct MnemonicArtifact: Codable, Equatable, Sendable {
    public let text: String
    public let anchor: AIArtifactAnchorSnapshot?

    public init(text: String, anchor: AIArtifactAnchorSnapshot? = nil) {
        self.text = text
        self.anchor = anchor
    }
}

public struct CollocationArtifact: Codable, Equatable, Sendable {
    public let phrase: String
    public let note: String?
    public let anchor: AIArtifactAnchorSnapshot?

    public init(
        phrase: String,
        note: String? = nil,
        anchor: AIArtifactAnchorSnapshot? = nil
    ) {
        self.phrase = phrase
        self.note = note
        self.anchor = anchor
    }
}

public enum RecallCardMode: String, Codable, CaseIterable, Sendable {
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

public struct RecallCardDraft: Codable, Equatable, Sendable {
    public let mode: RecallCardMode
    public let front: String
    public let back: String
    public let hint: String?
    public let anchor: AIArtifactAnchorSnapshot?

    public init(
        mode: RecallCardMode,
        front: String,
        back: String,
        hint: String? = nil,
        anchor: AIArtifactAnchorSnapshot? = nil
    ) {
        self.mode = mode
        self.front = front
        self.back = back
        self.hint = hint
        self.anchor = anchor
    }
}

public struct AIArtifacts: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let empty = AIArtifacts()

    public var schemaVersion: Int
    public var exampleSentences: AIArtifactSlot<[ExampleSentenceArtifact]>
    public var definitionNote: AIArtifactSlot<DefinitionNoteArtifact>
    public var recallCardDrafts: AIArtifactSlot<[RecallCardDraft]>
    public var pitfalls: AIArtifactSlot<[PitfallArtifact]>
    public var mnemonics: AIArtifactSlot<[MnemonicArtifact]>
    public var collocations: AIArtifactSlot<[CollocationArtifact]>

    public init(
        schemaVersion: Int = AIArtifacts.currentSchemaVersion,
        exampleSentences: AIArtifactSlot<[ExampleSentenceArtifact]> = .init(),
        definitionNote: AIArtifactSlot<DefinitionNoteArtifact> = .init(),
        recallCardDrafts: AIArtifactSlot<[RecallCardDraft]> = .init(),
        pitfalls: AIArtifactSlot<[PitfallArtifact]> = .init(),
        mnemonics: AIArtifactSlot<[MnemonicArtifact]> = .init(),
        collocations: AIArtifactSlot<[CollocationArtifact]> = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.exampleSentences = exampleSentences
        self.definitionNote = definitionNote
        self.recallCardDrafts = recallCardDrafts
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
    }

    public var isEmpty: Bool {
        exampleSentences.suggested == nil &&
            exampleSentences.accepted == nil &&
            definitionNote.suggested == nil &&
            definitionNote.accepted == nil &&
            recallCardDrafts.suggested == nil &&
            recallCardDrafts.accepted == nil &&
            pitfalls.suggested == nil &&
            pitfalls.accepted == nil &&
            mnemonics.suggested == nil &&
            mnemonics.accepted == nil &&
            collocations.suggested == nil &&
            collocations.accepted == nil
    }

    public init(
        legacySuggestedExampleSentences: [String] = [],
        legacyAcceptedExampleSentences: [String] = [],
        legacySuggestedDefinitionNote: String? = nil,
        legacyAcceptedDefinitionNote: String? = nil,
        legacySuggestedRecallCardDrafts: [RecallCardDraft] = [],
        legacyAcceptedRecallCardDrafts: [RecallCardDraft] = [],
        legacySuggestedPitfalls: [String] = [],
        legacyAcceptedPitfalls: [String] = [],
        legacySuggestedMnemonics: [String] = [],
        legacyAcceptedMnemonics: [String] = [],
        legacySuggestedCollocations: [String] = [],
        legacyAcceptedCollocations: [String] = []
    ) {
        self.init(
            exampleSentences: AIArtifactSlot(
                suggested: Self.makeExampleSentenceArtifacts(from: legacySuggestedExampleSentences),
                accepted: Self.makeExampleSentenceArtifacts(from: legacyAcceptedExampleSentences)
            ),
            definitionNote: AIArtifactSlot(
                suggested: Self.makeDefinitionNoteArtifact(from: legacySuggestedDefinitionNote),
                accepted: Self.makeDefinitionNoteArtifact(from: legacyAcceptedDefinitionNote)
            ),
            recallCardDrafts: AIArtifactSlot(
                suggested: legacySuggestedRecallCardDrafts.nilIfEmpty,
                accepted: legacyAcceptedRecallCardDrafts.nilIfEmpty
            ),
            pitfalls: AIArtifactSlot(
                suggested: Self.makePitfallArtifacts(from: legacySuggestedPitfalls),
                accepted: Self.makePitfallArtifacts(from: legacyAcceptedPitfalls)
            ),
            mnemonics: AIArtifactSlot(
                suggested: Self.makeMnemonicArtifacts(from: legacySuggestedMnemonics),
                accepted: Self.makeMnemonicArtifacts(from: legacyAcceptedMnemonics)
            ),
            collocations: AIArtifactSlot(
                suggested: Self.makeCollocationArtifacts(from: legacySuggestedCollocations),
                accepted: Self.makeCollocationArtifacts(from: legacyAcceptedCollocations)
            )
        )
    }

    public func fillingMissingSlots(
        legacySuggestedExampleSentences: [String] = [],
        legacyAcceptedExampleSentences: [String] = [],
        legacySuggestedDefinitionNote: String? = nil,
        legacyAcceptedDefinitionNote: String? = nil,
        legacySuggestedRecallCardDrafts: [RecallCardDraft] = [],
        legacyAcceptedRecallCardDrafts: [RecallCardDraft] = [],
        legacySuggestedPitfalls: [String] = [],
        legacyAcceptedPitfalls: [String] = [],
        legacySuggestedMnemonics: [String] = [],
        legacyAcceptedMnemonics: [String] = [],
        legacySuggestedCollocations: [String] = [],
        legacyAcceptedCollocations: [String] = []
    ) -> AIArtifacts {
        let legacy = AIArtifacts(
            legacySuggestedExampleSentences: legacySuggestedExampleSentences,
            legacyAcceptedExampleSentences: legacyAcceptedExampleSentences,
            legacySuggestedDefinitionNote: legacySuggestedDefinitionNote,
            legacyAcceptedDefinitionNote: legacyAcceptedDefinitionNote,
            legacySuggestedRecallCardDrafts: legacySuggestedRecallCardDrafts,
            legacyAcceptedRecallCardDrafts: legacyAcceptedRecallCardDrafts,
            legacySuggestedPitfalls: legacySuggestedPitfalls,
            legacyAcceptedPitfalls: legacyAcceptedPitfalls,
            legacySuggestedMnemonics: legacySuggestedMnemonics,
            legacyAcceptedMnemonics: legacyAcceptedMnemonics,
            legacySuggestedCollocations: legacySuggestedCollocations,
            legacyAcceptedCollocations: legacyAcceptedCollocations
        )

        return AIArtifacts(
            schemaVersion: schemaVersion,
            exampleSentences: AIArtifactSlot(
                suggested: exampleSentences.suggested ?? legacy.exampleSentences.suggested,
                accepted: exampleSentences.accepted ?? legacy.exampleSentences.accepted
            ),
            definitionNote: AIArtifactSlot(
                suggested: definitionNote.suggested ?? legacy.definitionNote.suggested,
                accepted: definitionNote.accepted ?? legacy.definitionNote.accepted
            ),
            recallCardDrafts: AIArtifactSlot(
                suggested: recallCardDrafts.suggested ?? legacy.recallCardDrafts.suggested,
                accepted: recallCardDrafts.accepted ?? legacy.recallCardDrafts.accepted
            ),
            pitfalls: AIArtifactSlot(
                suggested: pitfalls.suggested ?? legacy.pitfalls.suggested,
                accepted: pitfalls.accepted ?? legacy.pitfalls.accepted
            ),
            mnemonics: AIArtifactSlot(
                suggested: mnemonics.suggested ?? legacy.mnemonics.suggested,
                accepted: mnemonics.accepted ?? legacy.mnemonics.accepted
            ),
            collocations: AIArtifactSlot(
                suggested: collocations.suggested ?? legacy.collocations.suggested,
                accepted: collocations.accepted ?? legacy.collocations.accepted
            )
        )
    }

    public var suggestedExampleSentences: [String] {
        exampleSentences.suggested?.map(\.text) ?? []
    }

    public var acceptedExampleSentences: [String] {
        exampleSentences.accepted?.map(\.text) ?? []
    }

    public var suggestedDefinitionNoteText: String? {
        definitionNote.suggested?.text
    }

    public var acceptedDefinitionNoteText: String? {
        definitionNote.accepted?.text
    }

    public var suggestedRecallCardDrafts: [RecallCardDraft] {
        recallCardDrafts.suggested ?? []
    }

    public var acceptedRecallCardDrafts: [RecallCardDraft] {
        recallCardDrafts.accepted ?? []
    }

    public var suggestedPitfallTexts: [String] {
        pitfalls.suggested?.map(\.text) ?? []
    }

    public var acceptedPitfallTexts: [String] {
        pitfalls.accepted?.map(\.text) ?? []
    }

    public var suggestedMnemonicTexts: [String] {
        mnemonics.suggested?.map(\.text) ?? []
    }

    public var acceptedMnemonicTexts: [String] {
        mnemonics.accepted?.map(\.text) ?? []
    }

    public var suggestedCollocationPhrases: [String] {
        collocations.suggested?.map(\.phrase) ?? []
    }

    public var acceptedCollocationPhrases: [String] {
        collocations.accepted?.map(\.phrase) ?? []
    }

    private static func makeExampleSentenceArtifacts(from values: [String]) -> [ExampleSentenceArtifact]? {
        let items = values.compactMap(Self.makeExampleSentenceArtifact(from:))
        return items.nilIfEmpty
    }

    private static func makeExampleSentenceArtifact(from value: String) -> ExampleSentenceArtifact? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ExampleSentenceArtifact(text: trimmed)
    }

    private static func makeDefinitionNoteArtifact(from value: String?) -> DefinitionNoteArtifact? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return DefinitionNoteArtifact(text: trimmed)
    }

    private static func makePitfallArtifacts(from values: [String]) -> [PitfallArtifact]? {
        let items = values.compactMap { value -> PitfallArtifact? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return PitfallArtifact(text: trimmed)
        }
        return items.nilIfEmpty
    }

    private static func makeMnemonicArtifacts(from values: [String]) -> [MnemonicArtifact]? {
        let items = values.compactMap { value -> MnemonicArtifact? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return MnemonicArtifact(text: trimmed)
        }
        return items.nilIfEmpty
    }

    private static func makeCollocationArtifacts(from values: [String]) -> [CollocationArtifact]? {
        let items = values.compactMap { value -> CollocationArtifact? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return CollocationArtifact(phrase: trimmed)
        }
        return items.nilIfEmpty
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
