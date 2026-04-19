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

public struct AISenseReferenceSnapshot: Codable, Equatable, Sendable {
    public let senseIndex: Int?
    public let partOfSpeech: String?
    public let definitionSnapshot: String?

    public init(
        senseIndex: Int? = nil,
        partOfSpeech: String? = nil,
        definitionSnapshot: String? = nil
    ) {
        self.senseIndex = senseIndex
        self.partOfSpeech = partOfSpeech?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.definitionSnapshot = definitionSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct LearningAidSelectionOverlapHint: Codable, Equatable, Sendable {
    public let candidateID: String
    public let overlapType: String?
    public let withItemID: String?
    public let reason: String

    public init(
        candidateID: String,
        overlapType: String? = nil,
        withItemID: String? = nil,
        reason: String
    ) {
        self.candidateID = candidateID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.overlapType = overlapType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.withItemID = withItemID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LearningAidSectionSelection: Codable, Equatable, Sendable {
    public let recommendedID: String?
    public let alternativeIDs: [String]
    public let overlapHints: [LearningAidSelectionOverlapHint]
    public let whyRecommended: String?
    public let selectionSource: String?

    public init(
        recommendedID: String? = nil,
        alternativeIDs: [String] = [],
        overlapHints: [LearningAidSelectionOverlapHint] = [],
        whyRecommended: String? = nil,
        selectionSource: String? = nil
    ) {
        self.recommendedID = recommendedID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.alternativeIDs = alternativeIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.overlapHints = overlapHints.filter {
            !$0.candidateID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        self.whyRecommended = whyRecommended?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.selectionSource = selectionSource?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

public struct LearningAidSelections: Codable, Equatable, Sendable {
    public var pitfalls: LearningAidSectionSelection?
    public var mnemonics: LearningAidSectionSelection?
    public var collocations: LearningAidSectionSelection?

    public init(
        pitfalls: LearningAidSectionSelection? = nil,
        mnemonics: LearningAidSectionSelection? = nil,
        collocations: LearningAidSectionSelection? = nil
    ) {
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
    }
}

public struct PitfallArtifact: Codable, Equatable, Sendable {
    public let id: String?
    public let text: String
    public let translation: String?
    public let category: String?
    public let focus: String?
    public let recallRelevant: Bool?
    public let senseRef: AISenseReferenceSnapshot?
    public let anchor: AIArtifactAnchorSnapshot?

    public init(
        id: String? = nil,
        text: String,
        translation: String? = nil,
        category: String? = nil,
        focus: String? = nil,
        recallRelevant: Bool? = nil,
        senseRef: AISenseReferenceSnapshot? = nil,
        anchor: AIArtifactAnchorSnapshot? = nil
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.text = text
        self.translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.category = category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recallRelevant = recallRelevant
        self.senseRef = senseRef
        self.anchor = anchor
    }
}

public struct MnemonicArtifact: Codable, Equatable, Sendable {
    public let id: String?
    public let text: String
    public let translation: String?
    public let kind: String?
    public let focus: String?
    public let recallRelevant: Bool?
    public let senseRef: AISenseReferenceSnapshot?
    public let anchor: AIArtifactAnchorSnapshot?

    public init(
        id: String? = nil,
        text: String,
        translation: String? = nil,
        kind: String? = nil,
        focus: String? = nil,
        recallRelevant: Bool? = nil,
        senseRef: AISenseReferenceSnapshot? = nil,
        anchor: AIArtifactAnchorSnapshot? = nil
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.text = text
        self.translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recallRelevant = recallRelevant
        self.senseRef = senseRef
        self.anchor = anchor
    }
}

public struct CollocationArtifact: Codable, Equatable, Sendable {
    public let id: String?
    public let phrase: String
    public let note: String?
    public let focus: String?
    public let recallRelevant: Bool?
    public let senseRef: AISenseReferenceSnapshot?
    public let anchor: AIArtifactAnchorSnapshot?

    public init(
        id: String? = nil,
        phrase: String,
        note: String? = nil,
        focus: String? = nil,
        recallRelevant: Bool? = nil,
        senseRef: AISenseReferenceSnapshot? = nil,
        anchor: AIArtifactAnchorSnapshot? = nil
    ) {
        self.id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.phrase = phrase
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.recallRelevant = recallRelevant
        self.senseRef = senseRef
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
        case learningAidSelections
        case generatedIPANotationsByDialect
        case generatedStressSyllablesByDialect
    }

    public static let currentSchemaVersion = 4
    public static let empty = AIArtifacts()

    public var schemaVersion: Int
    public var exampleSentences: AIArtifactSlot<[ExampleSentenceArtifact]>
    public var definitionNote: AIArtifactSlot<DefinitionNoteArtifact>
    public var recallCardDrafts: AIArtifactSlot<[RecallCardDraft]>
    public var pitfalls: AIArtifactSlot<[PitfallArtifact]>
    public var mnemonics: AIArtifactSlot<[MnemonicArtifact]>
    public var collocations: AIArtifactSlot<[CollocationArtifact]>
    public var learningAidSelections: LearningAidSelections
    public var generatedIPANotationsByDialect: [String: String]
    public var generatedStressSyllablesByDialect: [String: String]

    public init(
        schemaVersion: Int = AIArtifacts.currentSchemaVersion,
        exampleSentences: AIArtifactSlot<[ExampleSentenceArtifact]> = .init(),
        definitionNote: AIArtifactSlot<DefinitionNoteArtifact> = .init(),
        recallCardDrafts: AIArtifactSlot<[RecallCardDraft]> = .init(),
        pitfalls: AIArtifactSlot<[PitfallArtifact]> = .init(),
        mnemonics: AIArtifactSlot<[MnemonicArtifact]> = .init(),
        collocations: AIArtifactSlot<[CollocationArtifact]> = .init(),
        learningAidSelections: LearningAidSelections = .init(),
        generatedIPANotationsByDialect: [String: String] = [:],
        generatedStressSyllablesByDialect: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.exampleSentences = exampleSentences
        self.definitionNote = definitionNote
        self.recallCardDrafts = recallCardDrafts
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
        self.learningAidSelections = learningAidSelections
        self.generatedIPANotationsByDialect = generatedIPANotationsByDialect
        self.generatedStressSyllablesByDialect = generatedStressSyllablesByDialect
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
            learningAidSelections: try container.decodeIfPresent(LearningAidSelections.self, forKey: .learningAidSelections) ?? .init(),
            generatedIPANotationsByDialect: try container.decodeIfPresent([String: String].self, forKey: .generatedIPANotationsByDialect) ?? [:],
            generatedStressSyllablesByDialect: try container.decodeIfPresent([String: String].self, forKey: .generatedStressSyllablesByDialect) ?? [:]
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
        try container.encode(normalized.learningAidSelections, forKey: .learningAidSelections)
        try container.encode(normalized.generatedIPANotationsByDialect, forKey: .generatedIPANotationsByDialect)
        try container.encode(normalized.generatedStressSyllablesByDialect, forKey: .generatedStressSyllablesByDialect)
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
            learningAidSelections.pitfalls == nil &&
            learningAidSelections.mnemonics == nil &&
            learningAidSelections.collocations == nil &&
            generatedIPANotationsByDialect.isEmpty &&
            generatedStressSyllablesByDialect.isEmpty
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
            learningAidSelections: .init(),
            generatedIPANotationsByDialect: [:],
            generatedStressSyllablesByDialect: [:]
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
            learningAidSelections: learningAidSelections,
            generatedIPANotationsByDialect: generatedIPANotationsByDialect,
            generatedStressSyllablesByDialect: generatedStressSyllablesByDialect
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
            learningAidSelections: Self.normalizeLearningAidSelections(learningAidSelections),
            generatedIPANotationsByDialect: Self.normalizeGeneratedStringByDialect(generatedIPANotationsByDialect),
            generatedStressSyllablesByDialect: Self.normalizeGeneratedStringByDialect(generatedStressSyllablesByDialect)
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

    public mutating func updateLearningAidSelection(
        for section: LearningAidSelectionSection,
        value: LearningAidSectionSelection?
    ) {
        switch section {
        case .pitfalls:
            learningAidSelections.pitfalls = value
        case .mnemonics:
            learningAidSelections.mnemonics = value
        case .collocations:
            learningAidSelections.collocations = value
        }
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
        artifacts?.enumerated().compactMap { index, artifact in
            let trimmed = artifact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return PitfallArtifact(
                id: normalizedArtifactID(
                    artifact.id,
                    prefix: "pitfall",
                    components: [trimmed, artifact.category, artifact.focus],
                    index: index
                ),
                text: trimmed,
                translation: artifact.translation,
                category: artifact.category,
                focus: artifact.focus,
                recallRelevant: artifact.recallRelevant,
                senseRef: artifact.senseRef,
                anchor: artifact.anchor
            )
        }.nilIfEmpty
    }

    private static func normalizeMnemonicArtifacts(_ artifacts: [MnemonicArtifact]?) -> [MnemonicArtifact]? {
        artifacts?.enumerated().compactMap { index, artifact in
            let trimmed = artifact.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return MnemonicArtifact(
                id: normalizedArtifactID(
                    artifact.id,
                    prefix: "mnemonic",
                    components: [trimmed, artifact.kind, artifact.focus],
                    index: index
                ),
                text: trimmed,
                translation: artifact.translation,
                kind: artifact.kind,
                focus: artifact.focus,
                recallRelevant: artifact.recallRelevant,
                senseRef: artifact.senseRef,
                anchor: artifact.anchor
            )
        }.nilIfEmpty
    }

    private static func normalizeCollocationArtifacts(_ artifacts: [CollocationArtifact]?) -> [CollocationArtifact]? {
        artifacts?.enumerated().compactMap { index, artifact in
            let phrase = artifact.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { return nil }
            let note = artifact.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return CollocationArtifact(
                id: normalizedArtifactID(
                    artifact.id,
                    prefix: "collocation",
                    components: [phrase, note, artifact.focus],
                    index: index
                ),
                phrase: phrase,
                note: note,
                focus: artifact.focus,
                recallRelevant: artifact.recallRelevant,
                senseRef: artifact.senseRef,
                anchor: artifact.anchor
            )
        }.nilIfEmpty
    }

    private static func normalizeLearningAidSelections(
        _ selections: LearningAidSelections
    ) -> LearningAidSelections {
        // Keep explicit selections intact even when the corresponding artifacts
        // are not present yet; they may be re-applied after a later refresh.
        LearningAidSelections(
            pitfalls: normalizeSectionSelection(selections.pitfalls),
            mnemonics: normalizeSectionSelection(selections.mnemonics),
            collocations: normalizeSectionSelection(selections.collocations)
        )
    }

    private static func normalizeSectionSelection(
        _ selection: LearningAidSectionSelection?
    ) -> LearningAidSectionSelection? {
        guard let selection else { return nil }

        let recommendedID = selection.recommendedID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let alternativeIDs = selection.alternativeIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let overlapHints = selection.overlapHints.filter {
            !$0.candidateID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !$0.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if recommendedID == nil &&
            alternativeIDs.isEmpty &&
            overlapHints.isEmpty &&
            selection.whyRecommended == nil &&
            selection.selectionSource == nil {
            return nil
        }

        return LearningAidSectionSelection(
            recommendedID: recommendedID,
            alternativeIDs: alternativeIDs,
            overlapHints: overlapHints,
            whyRecommended: selection.whyRecommended,
            selectionSource: selection.selectionSource
        )
    }

    private static func normalizedArtifactID(
        _ id: String?,
        prefix: String,
        components: [String?],
        index: Int
    ) -> String {
        if let normalized = id?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty {
            return normalized
        }

        let slug = components
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmpty }
            .joined(separator: "|")
            .replacingOccurrences(of: #"[^a-z0-9|]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-|"))

        return slug.isEmpty ? "\(prefix)-\(index)" : "\(prefix)-\(index)-\(slug)"
    }

    private static func normalizeGeneratedStringByDialect(_ values: [String: String]) -> [String: String] {
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

public enum LearningAidSelectionSection: String, Codable, Equatable, Sendable {
    case pitfalls
    case mnemonics
    case collocations
}
