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
    private enum CodingKeys: String, CodingKey {
        case text
        case translation
        case note
        case anchor
    }

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
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = normalizedText
        self.translation = Self.inferredTranslation(from: normalizedText)
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.anchor = anchor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try container.decode(String.self, forKey: .text),
            translation: try container.decodeIfPresent(String.self, forKey: .translation),
            note: try container.decodeIfPresent(String.self, forKey: .note),
            anchor: try container.decodeIfPresent(AIArtifactAnchorSnapshot.self, forKey: .anchor)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(translation, forKey: .translation)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(anchor, forKey: .anchor)
    }

    public var renderedText: String {
        text
    }

    public static func inferredTranslation(from text: String) -> String? {
        guard let separatorRange = text.range(of: "—", options: .backwards) else { return nil }

        let sourceText = text[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let translationText = text[separatorRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty, !translationText.isEmpty else { return nil }
        return translationText
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
    private struct RawExampleSentenceArtifact: Codable, Equatable, Sendable {
        let text: String
        let translation: String?
        let note: String?
        let anchor: AIArtifactAnchorSnapshot?
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case exampleSentences
        case definitionNote
        case recallCardDrafts
        case pitfalls
        case mnemonics
        case collocations
        case generatedIPANotationsByDialect
    }

    public static let currentSchemaVersion = 2
    public static let empty = AIArtifacts()

    public var schemaVersion: Int
    public var exampleSentences: AIArtifactSlot<[ExampleSentenceArtifact]>
    public var definitionNote: AIArtifactSlot<DefinitionNoteArtifact>
    public var recallCardDrafts: AIArtifactSlot<[RecallCardDraft]>
    public var pitfalls: AIArtifactSlot<[PitfallArtifact]>
    public var mnemonics: AIArtifactSlot<[MnemonicArtifact]>
    public var collocations: AIArtifactSlot<[CollocationArtifact]>
    public var generatedIPANotationsByDialect: [String: String]

    public init(
        schemaVersion: Int = AIArtifacts.currentSchemaVersion,
        exampleSentences: AIArtifactSlot<[ExampleSentenceArtifact]> = .init(),
        definitionNote: AIArtifactSlot<DefinitionNoteArtifact> = .init(),
        recallCardDrafts: AIArtifactSlot<[RecallCardDraft]> = .init(),
        pitfalls: AIArtifactSlot<[PitfallArtifact]> = .init(),
        mnemonics: AIArtifactSlot<[MnemonicArtifact]> = .init(),
        collocations: AIArtifactSlot<[CollocationArtifact]> = .init(),
        generatedIPANotationsByDialect: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.exampleSentences = exampleSentences
        self.definitionNote = definitionNote
        self.recallCardDrafts = recallCardDrafts
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
        self.generatedIPANotationsByDialect = generatedIPANotationsByDialect
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = AIArtifacts(
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? AIArtifacts.currentSchemaVersion,
            exampleSentences: Self.decodeExampleSentenceSlot(from: container),
            definitionNote: try container.decodeIfPresent(AIArtifactSlot<DefinitionNoteArtifact>.self, forKey: .definitionNote) ?? .init(),
            recallCardDrafts: try container.decodeIfPresent(AIArtifactSlot<[RecallCardDraft]>.self, forKey: .recallCardDrafts) ?? .init(),
            pitfalls: try container.decodeIfPresent(AIArtifactSlot<[PitfallArtifact]>.self, forKey: .pitfalls) ?? .init(),
            mnemonics: try container.decodeIfPresent(AIArtifactSlot<[MnemonicArtifact]>.self, forKey: .mnemonics) ?? .init(),
            collocations: try container.decodeIfPresent(AIArtifactSlot<[CollocationArtifact]>.self, forKey: .collocations) ?? .init(),
            generatedIPANotationsByDialect: try container.decodeIfPresent([String: String].self, forKey: .generatedIPANotationsByDialect) ?? [:]
        ).normalized()
    }

    public func encode(to encoder: Encoder) throws {
        let normalized = normalized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalized.schemaVersion, forKey: .schemaVersion)
        try container.encode(normalized.exampleSentences, forKey: .exampleSentences)
        try container.encode(normalized.definitionNote, forKey: .definitionNote)
        try container.encode(normalized.recallCardDrafts, forKey: .recallCardDrafts)
        try container.encode(normalized.pitfalls, forKey: .pitfalls)
        try container.encode(normalized.mnemonics, forKey: .mnemonics)
        try container.encode(normalized.collocations, forKey: .collocations)
        try container.encode(normalized.generatedIPANotationsByDialect, forKey: .generatedIPANotationsByDialect)
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
            collocations.accepted == nil &&
            generatedIPANotationsByDialect.isEmpty
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
        self = AIArtifacts(
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
            ),
            generatedIPANotationsByDialect: [:]
        ).normalized()
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
            ),
            generatedIPANotationsByDialect: generatedIPANotationsByDialect
        ).normalized()
    }

    public func normalized() -> AIArtifacts {
        AIArtifacts(
            schemaVersion: schemaVersion,
            exampleSentences: AIArtifactSlot(
                suggested: Self.normalizeExampleArtifacts(exampleSentences.suggested),
                accepted: Self.normalizeExampleArtifacts(exampleSentences.accepted)
            ),
            definitionNote: AIArtifactSlot(
                suggested: Self.normalizeDefinitionNoteArtifact(definitionNote.suggested),
                accepted: Self.normalizeDefinitionNoteArtifact(definitionNote.accepted)
            ),
            recallCardDrafts: AIArtifactSlot(
                suggested: Self.normalizeRecallCardDrafts(recallCardDrafts.suggested),
                accepted: Self.normalizeRecallCardDrafts(recallCardDrafts.accepted)
            ),
            pitfalls: AIArtifactSlot(
                suggested: Self.normalizePitfallArtifacts(pitfalls.suggested),
                accepted: Self.normalizePitfallArtifacts(pitfalls.accepted)
            ),
            mnemonics: AIArtifactSlot(
                suggested: Self.normalizeMnemonicArtifacts(mnemonics.suggested),
                accepted: Self.normalizeMnemonicArtifacts(mnemonics.accepted)
            ),
            collocations: AIArtifactSlot(
                suggested: Self.normalizeCollocationArtifacts(collocations.suggested),
                accepted: Self.normalizeCollocationArtifacts(collocations.accepted)
            ),
            generatedIPANotationsByDialect: Self.normalizeGeneratedIPANotations(generatedIPANotationsByDialect)
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
        normalizeExampleArtifacts(values.compactMap(Self.makeExampleSentenceArtifact(from:)))
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

    private static func normalizeExampleArtifacts(_ artifacts: [ExampleSentenceArtifact]?) -> [ExampleSentenceArtifact]? {
        artifacts?.compactMap { artifact in
            let normalized = ExampleSentenceArtifact(
                text: artifact.text,
                note: artifact.note,
                anchor: artifact.anchor
            )
            return normalized.text.isEmpty ? nil : normalized
        }.nilIfEmpty
    }

    private static func decodeExampleSentenceSlot(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> AIArtifactSlot<[ExampleSentenceArtifact]> {
        guard let rawSlot = try? container.decodeIfPresent(
            AIArtifactSlot<[RawExampleSentenceArtifact]>.self,
            forKey: .exampleSentences
        ) else {
            return .init()
        }

        return AIArtifactSlot(
            suggested: rawSlot.suggested?.compactMap(Self.decodeExampleSentenceArtifact(from:)).nilIfEmpty,
            accepted: rawSlot.accepted?.compactMap(Self.decodeExampleSentenceArtifact(from:)).nilIfEmpty
        )
    }

    private static func decodeExampleSentenceArtifact(
        from raw: RawExampleSentenceArtifact
    ) -> ExampleSentenceArtifact? {
        let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let translation = raw.translation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let effectiveText: String
        if ExampleSentenceArtifact.inferredTranslation(from: text) == nil, let translation {
            effectiveText = "\(text) — \(translation)"
        } else {
            effectiveText = text
        }

        return ExampleSentenceArtifact(
            text: effectiveText,
            note: raw.note,
            anchor: raw.anchor
        )
    }

    private static func normalizeDefinitionNoteArtifact(_ artifact: DefinitionNoteArtifact?) -> DefinitionNoteArtifact? {
        guard let trimmed = artifact?.text.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return DefinitionNoteArtifact(text: trimmed, anchor: artifact?.anchor)
    }

    private static func normalizeRecallCardDrafts(_ drafts: [RecallCardDraft]?) -> [RecallCardDraft]? {
        drafts?.compactMap { draft in
            let front = draft.front.trimmingCharacters(in: .whitespacesAndNewlines)
            let back = draft.back.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !front.isEmpty, !back.isEmpty else { return nil }
            let hint = draft.hint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return RecallCardDraft(
                mode: draft.mode,
                front: front,
                back: back,
                hint: hint,
                anchor: draft.anchor
            )
        }.nilIfEmpty
    }

    private static func normalizePitfallArtifacts(_ artifacts: [PitfallArtifact]?) -> [PitfallArtifact]? {
        artifacts?.compactMap { artifact in
            let trimmed = artifact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return PitfallArtifact(text: trimmed, anchor: artifact.anchor)
        }.nilIfEmpty
    }

    private static func normalizeMnemonicArtifacts(_ artifacts: [MnemonicArtifact]?) -> [MnemonicArtifact]? {
        artifacts?.compactMap { artifact in
            let trimmed = artifact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return MnemonicArtifact(text: trimmed, anchor: artifact.anchor)
        }.nilIfEmpty
    }

    private static func normalizeCollocationArtifacts(_ artifacts: [CollocationArtifact]?) -> [CollocationArtifact]? {
        artifacts?.compactMap { artifact in
            let phrase = artifact.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { return nil }
            let note = artifact.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return CollocationArtifact(phrase: phrase, note: note, anchor: artifact.anchor)
        }.nilIfEmpty
    }

    private static func normalizeGeneratedIPANotations(_ values: [String: String]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: values.compactMap { key, value in
                let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedKey.isEmpty, !normalizedValue.isEmpty else { return nil }
                return (normalizedKey, normalizedValue)
            }
        )
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
