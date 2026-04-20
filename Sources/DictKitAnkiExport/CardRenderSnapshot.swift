import DictKit
import Foundation

/// A pure-data snapshot of a rendered card, designed to be consumed by the
/// Agent chat layer.
///
/// It bundles two complementary representations of the same card:
///
/// - `wireframe`: a plain-text ASCII diagram that mimics the final rendered
///   layout. Meant for the Agent to develop a visual/spatial sense of "what
///   the user actually sees" without having to reconstruct space from JSON.
/// - `structuredJSON`: a stable, id-addressable JSON document describing the
///   same card. Meant for the Agent to reference when calling write tools
///   (e.g. "replace example with id `ex-1`").
///
/// `CardRenderSnapshot` is deterministic: the same inputs always produce the
/// same output, which lets tests snapshot the wireframe and lets the context
/// builder avoid redundant work across turns.
///
/// See `docs/specs/llm-features/50-agent-chat.md` §4.4 for the product-level
/// contract.
public struct CardRenderSnapshot: Equatable, Sendable {
    /// Which card variant this snapshot describes.
    public enum Kind: String, Sendable, Equatable {
        case standard
        case recall
    }

    /// The AI section identifiers in the order they appear on the rendered
    /// back, matching `AnkiFieldFormatter.aiSupplementHTML`.
    ///
    /// Having this as a public enum lets the wireframe and the structured JSON
    /// agree on an ordering, and lets tests assert "these two views are in
    /// sync" without string comparisons.
    public enum AISection: String, Sendable, Equatable, CaseIterable {
        case usageCue
        case examples
        case pitfalls
        case mnemonics
        case collocations
    }

    public let kind: Kind
    public let word: String
    public let phonetic: String
    public let wireframe: String
    public let structuredJSON: String
    public let aiSectionOrder: [AISection]

    public init(
        kind: Kind,
        word: String,
        phonetic: String,
        wireframe: String,
        structuredJSON: String,
        aiSectionOrder: [AISection]
    ) {
        self.kind = kind
        self.word = word
        self.phonetic = phonetic
        self.wireframe = wireframe
        self.structuredJSON = structuredJSON
        self.aiSectionOrder = aiSectionOrder
    }
}

public enum CardRenderSnapshotBuilder {
    /// The canonical AI section order, kept in lockstep with
    /// `AnkiFieldFormatter.aiSupplementHTML` so wireframe and exported HTML
    /// never drift.
    public static let canonicalAISectionOrder: [CardRenderSnapshot.AISection] = [
        .usageCue,
        .examples,
        .pitfalls,
        .mnemonics,
        .collocations
    ]

    /// Build a Standard-card snapshot from a dictionary lookup and the
    /// accepted AI artifacts that would be baked into the final card.
    ///
    /// The snapshot reflects "what the user would see right now" — only the
    /// accepted slots are considered. Suggested-but-not-applied artifacts
    /// belong to the structured panel / Agent proposal flow, not to the card
    /// surface.
    public static func standard(
        word: String,
        lookupResult: LookupResult,
        aiArtifacts: AIArtifacts
    ) -> CardRenderSnapshot {
        let normalizedArtifacts = aiArtifacts.normalized()
        let displayWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let phonetic = AnkiFieldFormatter.phoneticDisplay(
            from: lookupResult,
            aiArtifacts: normalizedArtifacts
        )

        let senses = StructuredSenseExtractor.senses(from: lookupResult)
        let aiPresence = AIArtifactPresence(from: normalizedArtifacts)
        let orderedSections = canonicalAISectionOrder.filter { aiPresence.isPresent($0) }

        let wireframe = StandardWireframeRenderer.render(
            word: displayWord,
            phonetic: phonetic,
            senses: senses,
            artifacts: normalizedArtifacts,
            aiPresence: aiPresence
        )

        let structuredJSON = StandardStructuredJSONRenderer.render(
            word: displayWord,
            phonetic: phonetic,
            senses: senses,
            artifacts: normalizedArtifacts
        )

        return CardRenderSnapshot(
            kind: .standard,
            word: displayWord,
            phonetic: phonetic,
            wireframe: wireframe,
            structuredJSON: structuredJSON,
            aiSectionOrder: orderedSections
        )
    }

    /// Build a Recall-card snapshot from the accepted recall draft.
    ///
    /// If no accepted recall draft exists, the wireframe shows a placeholder
    /// so the Agent knows the user hasn't saved one yet. The `phonetic` and
    /// reference-entry fields still come from the source lookup so the Agent
    /// can reason about the underlying word.
    public static func recall(
        word: String,
        lookupResult: LookupResult,
        aiArtifacts: AIArtifacts
    ) -> CardRenderSnapshot {
        let normalizedArtifacts = aiArtifacts.normalized()
        let displayWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let phonetic = AnkiFieldFormatter.phoneticDisplay(
            from: lookupResult,
            aiArtifacts: normalizedArtifacts
        )
        let senses = StructuredSenseExtractor.senses(from: lookupResult)
        let draft = normalizedArtifacts.recallCardDrafts.accepted?.first

        let wireframe = RecallWireframeRenderer.render(
            word: displayWord,
            phonetic: phonetic,
            draft: draft,
            senses: senses
        )

        let structuredJSON = RecallStructuredJSONRenderer.render(
            word: displayWord,
            phonetic: phonetic,
            draft: draft,
            senses: senses
        )

        return CardRenderSnapshot(
            kind: .recall,
            word: displayWord,
            phonetic: phonetic,
            wireframe: wireframe,
            structuredJSON: structuredJSON,
            aiSectionOrder: []
        )
    }
}

// MARK: - Internal helpers

/// A flattened view of the senses in a `LookupResult`, keyed by a stable id
/// `sense-<lexicalEntryIndex>-<senseIndex>` so wireframe and JSON agree.
struct StructuredSense: Equatable {
    let id: String
    let lexicalEntryIndex: Int
    let senseIndex: Int
    let partOfSpeech: String
    let semanticHint: String?
    let registers: [String]
    let definition: String
    let examples: [String]
}

enum StructuredSenseExtractor {
    static func senses(from result: LookupResult) -> [StructuredSense] {
        var collected: [StructuredSense] = []
        for entry in result.entries {
            for (lexIdx, lex) in entry.lexicalEntries.enumerated() {
                for (senseIdx, sense) in lex.senses.enumerated() {
                    let trimmedDefinition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedDefinition.isEmpty else { continue }
                    let hint = sense.semanticHint?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                    let registers = sense.registers
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let examples = sense.examples
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }

                    collected.append(
                        StructuredSense(
                            id: "sense-\(lexIdx)-\(senseIdx)",
                            lexicalEntryIndex: lexIdx,
                            senseIndex: senseIdx,
                            partOfSpeech: lex.partOfSpeechLabel,
                            semanticHint: hint,
                            registers: registers,
                            definition: trimmedDefinition,
                            examples: examples
                        )
                    )
                }
            }
        }
        return collected
    }
}

/// Quick test for "does the card visibly contain this AI section right now?"
struct AIArtifactPresence {
    let hasUsageCue: Bool
    let hasExamples: Bool
    let hasPitfalls: Bool
    let hasMnemonics: Bool
    let hasCollocations: Bool

    init(from artifacts: AIArtifacts) {
        self.hasUsageCue = (artifacts.definitionNote.accepted?.text.nonEmpty) != nil
        self.hasExamples = !(artifacts.exampleSentences.accepted?.isEmpty ?? true)
        self.hasPitfalls = !(artifacts.pitfalls.accepted?.isEmpty ?? true)
        self.hasMnemonics = !(artifacts.mnemonics.accepted?.isEmpty ?? true)
        self.hasCollocations = !(artifacts.collocations.accepted?.isEmpty ?? true)
    }

    func isPresent(_ section: CardRenderSnapshot.AISection) -> Bool {
        switch section {
        case .usageCue: return hasUsageCue
        case .examples: return hasExamples
        case .pitfalls: return hasPitfalls
        case .mnemonics: return hasMnemonics
        case .collocations: return hasCollocations
        }
    }
}

extension String {
    fileprivate var nonEmpty: String? { isEmpty ? nil : self }
}
