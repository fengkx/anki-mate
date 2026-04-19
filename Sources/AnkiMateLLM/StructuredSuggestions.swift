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

public struct LLMRecallGenerationContext: Codable, Equatable, Sendable {
    public let acceptedPitfalls: [String]
    public let acceptedUsageHints: [String]
    public let acceptedMnemonics: [String]
    public let acceptedCollocations: [String]

    public init(
        acceptedPitfalls: [String] = [],
        acceptedUsageHints: [String] = [],
        acceptedMnemonics: [String] = [],
        acceptedCollocations: [String] = []
    ) {
        self.acceptedPitfalls = acceptedPitfalls
        self.acceptedUsageHints = acceptedUsageHints
        self.acceptedMnemonics = acceptedMnemonics
        self.acceptedCollocations = acceptedCollocations
    }
}

public struct LLMRecallWordSignals: Codable, Equatable, Sendable {
    public let isPhrase: Bool
    public let hasRepeatedLetters: Bool
    public let hasConfusableVowelCluster: Bool

    public init(
        isPhrase: Bool,
        hasRepeatedLetters: Bool,
        hasConfusableVowelCluster: Bool
    ) {
        self.isPhrase = isPhrase
        self.hasRepeatedLetters = hasRepeatedLetters
        self.hasConfusableVowelCluster = hasConfusableVowelCluster
    }
}

public struct LLMRecallSelectionReason: Codable, Equatable, Sendable {
    public let primaryGoal: String
    public let evidence: [String]

    public init(primaryGoal: String, evidence: [String]) {
        self.primaryGoal = primaryGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evidence = evidence.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

public struct LLMRecallCuePlan: Codable, Equatable, Sendable {
    public let semanticSource: String
    public let normalizedCue: String

    public init(semanticSource: String, normalizedCue: String) {
        self.semanticSource = semanticSource.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedCue = normalizedCue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RecallCardDraftDecisionEnvelope: Codable, Equatable, Sendable {
    public let draft: LLMRecallCardDraft
    public let selectionReason: LLMRecallSelectionReason?
    public let cuePlan: LLMRecallCuePlan?

    public init(
        draft: LLMRecallCardDraft,
        selectionReason: LLMRecallSelectionReason? = nil,
        cuePlan: LLMRecallCuePlan? = nil
    ) {
        self.draft = draft
        self.selectionReason = selectionReason
        self.cuePlan = cuePlan
    }
}

public struct LLMPitfall: Codable, Equatable, Sendable {
    public let id: String
    public let summary: String
    public let translation: String?
    public let category: String?
    public let focus: String?
    public let recallRelevant: Bool?
    public let senseIndex: Int?
    public let details: String?
    public let anchor: LLMAnchorSnapshot?

    public init(
        id: String = UUID().uuidString,
        summary: String,
        translation: String? = nil,
        category: String? = nil,
        focus: String? = nil,
        recallRelevant: Bool? = nil,
        senseIndex: Int? = nil,
        details: String? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recallRelevant = recallRelevant
        self.senseIndex = senseIndex
        self.details = details?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anchor = anchor
    }
}

public struct LLMMnemonic: Codable, Equatable, Sendable {
    public let id: String
    public let clue: String
    public let translation: String?
    public let kind: String?
    public let focus: String?
    public let recallRelevant: Bool?
    public let senseIndex: Int?
    public let anchor: LLMAnchorSnapshot?

    public init(
        id: String = UUID().uuidString,
        clue: String,
        translation: String? = nil,
        kind: String? = nil,
        focus: String? = nil,
        recallRelevant: Bool? = nil,
        senseIndex: Int? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clue = clue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.translation = translation?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recallRelevant = recallRelevant
        self.senseIndex = senseIndex
        self.anchor = anchor
    }
}

public struct LLMCollocation: Codable, Equatable, Sendable {
    public let id: String
    public let phrase: String
    public let gloss: String?
    public let focus: String?
    public let recallRelevant: Bool?
    public let senseIndex: Int?
    public let anchor: LLMAnchorSnapshot?

    public init(
        id: String = UUID().uuidString,
        phrase: String,
        gloss: String? = nil,
        focus: String? = nil,
        recallRelevant: Bool? = nil,
        senseIndex: Int? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) {
        self.id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        self.gloss = gloss?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recallRelevant = recallRelevant
        self.senseIndex = senseIndex
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

public enum LLMLearningAidSection: String, Codable, CaseIterable, Sendable {
    case pitfalls
    case mnemonics
    case collocations
}

public enum LLMLearningAidJudgeStrategy: String, Codable, CaseIterable, Sendable {
    case separateSections
    case combinedSections
}

public struct LLMLearningAidAcceptedContext: Codable, Equatable, Sendable {
    public let acceptedPitfalls: [String]
    public let acceptedUsageHints: [String]
    public let acceptedMnemonics: [String]
    public let acceptedCollocations: [String]

    public init(
        acceptedPitfalls: [String] = [],
        acceptedUsageHints: [String] = [],
        acceptedMnemonics: [String] = [],
        acceptedCollocations: [String] = []
    ) {
        self.acceptedPitfalls = acceptedPitfalls
        self.acceptedUsageHints = acceptedUsageHints
        self.acceptedMnemonics = acceptedMnemonics
        self.acceptedCollocations = acceptedCollocations
    }
}

public struct LLMLearningAidOverlapHint: Codable, Equatable, Sendable {
    public let candidateID: String
    public let overlapType: String?
    public let withItemID: String?
    public let reason: String

    public init(candidateID: String, overlapType: String? = nil, withItemID: String? = nil, reason: String) {
        self.candidateID = candidateID
        self.overlapType = overlapType
        self.withItemID = withItemID
        self.reason = reason
    }
}

public struct LLMLearningAidSectionSelection: Codable, Equatable, Sendable {
    public let recommendedID: String?
    public let alternativeIDs: [String]
    public let overlapHints: [LLMLearningAidOverlapHint]
    public let whyRecommended: String?
    public let selectionSource: String?

    public init(
        recommendedID: String? = nil,
        alternativeIDs: [String] = [],
        overlapHints: [LLMLearningAidOverlapHint] = [],
        whyRecommended: String? = nil,
        selectionSource: String? = nil
    ) {
        self.recommendedID = recommendedID
        self.alternativeIDs = alternativeIDs
        self.overlapHints = overlapHints
        self.whyRecommended = whyRecommended
        self.selectionSource = selectionSource
    }
}

public struct LLMLearningAidSelections: Codable, Equatable, Sendable {
    public let pitfalls: LLMLearningAidSectionSelection?
    public let mnemonics: LLMLearningAidSectionSelection?
    public let collocations: LLMLearningAidSectionSelection?

    public init(
        pitfalls: LLMLearningAidSectionSelection? = nil,
        mnemonics: LLMLearningAidSectionSelection? = nil,
        collocations: LLMLearningAidSectionSelection? = nil
    ) {
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
    }
}

public struct LLMLearningAidsRankedResult: Codable, Equatable, Sendable {
    public let aids: LLMLearningAids
    public let selections: LLMLearningAidSelections

    public init(aids: LLMLearningAids, selections: LLMLearningAidSelections) {
        self.aids = aids
        self.selections = selections
    }
}
