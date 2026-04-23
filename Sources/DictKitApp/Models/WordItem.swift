import DictKit
import DictKitAnkiExport
import DictKitSystemDictionary
import Foundation
import SwiftUI

enum LookupState: Equatable {
    case pending
    case loading
    case loaded(LookupResult)
    case failed(String)

    static func == (lhs: LookupState, rhs: LookupState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.loading, .loading): return true
        case (.loaded(let a), .loaded(let b)): return a == b
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

final class WordItem: ObservableObject, Identifiable {
    let id: UUID
    @Published var word: String
    @Published var sourceForm: String?
    @Published var inflectionKind: InflectionKind?
    @Published var expectedPartOfSpeech: PartOfSpeech?
    let createdAt: Date

    @Published var lookupState: LookupState
    @Published var audioData: Data?
    @Published var isSynthesizingAudio: Bool = false
    @Published var isRefreshing: Bool = false
    @Published var refreshErrorMessage: String?
    @Published var updatedAt: Date
    @Published var lastRefreshedAt: Date?

    // AI artifacts are stored in a single typed schema with suggested/accepted slots.
    @Published var aiArtifacts: AIArtifacts = .empty
    @Published var isGeneratingAI: Bool = false

    var aiSuggestedExampleArtifacts: [ExampleSentenceArtifact] {
        get { aiArtifacts.exampleSentences.suggested ?? [] }
        set { aiArtifacts.exampleSentences.suggested = newValue.compactMap(normalizeExampleArtifact).nilIfEmpty }
    }

    var aiAcceptedExampleArtifacts: [ExampleSentenceArtifact] {
        get { aiArtifacts.exampleSentences.accepted ?? [] }
        set { aiArtifacts.exampleSentences.accepted = newValue.compactMap(normalizeExampleArtifact).nilIfEmpty }
    }

    var aiSuggestedExampleSentences: [String] {
        get { aiSuggestedExampleArtifacts.map(\.text) }
        set {
            aiSuggestedExampleArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ExampleSentenceArtifact(text: trimmed)
            }
        }
    }

    var aiAcceptedExampleSentences: [String] {
        get { aiAcceptedExampleArtifacts.map(\.text) }
        set {
            aiAcceptedExampleArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ExampleSentenceArtifact(text: trimmed)
            }
        }
    }

    var aiSuggestedDefinitionNote: String? {
        get { aiArtifacts.suggestedDefinitionNoteText }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                aiArtifacts.definitionNote.suggested = DefinitionNoteArtifact(text: trimmed)
            } else {
                aiArtifacts.definitionNote.suggested = nil
            }
        }
    }

    var aiAcceptedDefinitionNote: String? {
        get { aiArtifacts.acceptedDefinitionNoteText }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                aiArtifacts.definitionNote.accepted = DefinitionNoteArtifact(text: trimmed)
            } else {
                aiArtifacts.definitionNote.accepted = nil
            }
        }
    }

    var aiSuggestedRecallCardDrafts: [RecallCardDraft] {
        get { aiArtifacts.recallCardDrafts.suggested ?? [] }
        set { aiArtifacts.recallCardDrafts.suggested = newValue.nilIfEmpty }
    }

    var aiAcceptedRecallCardDrafts: [RecallCardDraft] {
        get { aiArtifacts.recallCardDrafts.accepted ?? [] }
        set {
            let normalized = newValue.last.map { [$0] }
            aiArtifacts.recallCardDrafts.accepted = normalized
        }
    }

    var aiSuggestedPitfalls: [String] {
        get { aiSuggestedPitfallArtifacts.map(\.text) }
        set {
            aiSuggestedPitfallArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return PitfallArtifact(text: trimmed)
            }
        }
    }

    var aiAcceptedPitfalls: [String] {
        get { aiAcceptedPitfallArtifacts.map(\.text) }
        set {
            aiAcceptedPitfallArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return PitfallArtifact(text: trimmed)
            }
        }
    }

    var aiSuggestedMnemonics: [String] {
        get { aiSuggestedMnemonicArtifacts.map(\.text) }
        set {
            aiSuggestedMnemonicArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return MnemonicArtifact(text: trimmed)
            }
        }
    }

    var aiAcceptedMnemonics: [String] {
        get { aiAcceptedMnemonicArtifacts.map(\.text) }
        set {
            aiAcceptedMnemonicArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return MnemonicArtifact(text: trimmed)
            }
        }
    }

    var aiSuggestedCollocations: [String] {
        get { aiSuggestedCollocationArtifacts.map(\.phrase) }
        set {
            aiSuggestedCollocationArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return CollocationArtifact(phrase: trimmed)
            }
        }
    }

    var aiAcceptedCollocations: [String] {
        get { aiAcceptedCollocationArtifacts.map(\.phrase) }
        set {
            aiAcceptedCollocationArtifacts = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return CollocationArtifact(phrase: trimmed)
            }
        }
    }

    var aiSuggestedPitfallArtifacts: [PitfallArtifact] {
        get { aiArtifacts.pitfalls.suggested ?? [] }
        set { aiArtifacts.pitfalls.suggested = newValue.nilIfEmpty }
    }

    var aiAcceptedPitfallArtifacts: [PitfallArtifact] {
        get { aiArtifacts.pitfalls.accepted ?? [] }
        set { aiArtifacts.pitfalls.accepted = newValue.nilIfEmpty }
    }

    var aiSuggestedMnemonicArtifacts: [MnemonicArtifact] {
        get { aiArtifacts.mnemonics.suggested ?? [] }
        set { aiArtifacts.mnemonics.suggested = newValue.nilIfEmpty }
    }

    var aiAcceptedMnemonicArtifacts: [MnemonicArtifact] {
        get { aiArtifacts.mnemonics.accepted ?? [] }
        set { aiArtifacts.mnemonics.accepted = newValue.nilIfEmpty }
    }

    var aiSuggestedCollocationArtifacts: [CollocationArtifact] {
        get { aiArtifacts.collocations.suggested ?? [] }
        set { aiArtifacts.collocations.suggested = newValue.nilIfEmpty }
    }

    var aiAcceptedCollocationArtifacts: [CollocationArtifact] {
        get { aiArtifacts.collocations.accepted ?? [] }
        set { aiArtifacts.collocations.accepted = newValue.nilIfEmpty }
    }

    var normalizedWord: String {
        WordListStore.normalizedWord(for: word)
    }

    var sourceDescription: String? {
        guard let sourceForm, !sourceForm.isEmpty else { return nil }
        if let inflectionKind {
            return "from \"\(sourceForm)\" · \(inflectionKind.shortDescription)"
        }
        return "from \"\(sourceForm)\""
    }

    var inflectionDescription: String? {
        guard let inflectionKind else { return nil }
        if let expectedPartOfSpeech {
            return "\(expectedPartOfSpeech.rawValue) · \(inflectionKind.shortDescription)"
        }
        return inflectionKind.shortDescription
    }

    var lookupResult: LookupResult? {
        if case .loaded(let result) = lookupState { return result }
        return nil
    }

    var phonetic: String {
        if let generatedIPA = preferredGeneratedIPA {
            return "/\(generatedIPA)/"
        }
        guard let result = lookupResult else { return "" }
        return AnkiFieldFormatter.phoneticDisplay(from: result)
    }

    var phoneticsByDialect: [(dialect: String, notation: String, usesIPADelimiters: Bool, pronunciation: Pronunciation)] {
        guard let result = lookupResult else { return [] }
        var seen = Set<String>()
        var items: [(dialect: String, notation: String, usesIPADelimiters: Bool, pronunciation: Pronunciation)] = []
        for entry in result.entries {
            let allPronunciations = entry.pronunciations.isEmpty
                ? entry.lexicalEntries.flatMap(\.pronunciations)
                : entry.pronunciations
            for p in allPronunciations {
                let notation = p.displayNotation.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !notation.isEmpty else { continue }
                let dialect = p.dialect ?? ""
                let key = "\(dialect):\(p.usesIPADelimitersForDisplay):\(notation)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                items.append((
                    dialect: dialect,
                    notation: notation,
                    usesIPADelimiters: p.usesIPADelimitersForDisplay,
                    pronunciation: p
                ))
            }
        }
        return items
    }

    var hasTrueIPA: Bool {
        phoneticsByDialect.contains { $0.usesIPADelimiters }
    }

    var hasDisplayIPA: Bool {
        hasTrueIPA || preferredGeneratedIPA != nil
    }

    var preferredGeneratedIPA: String? {
        generatedIPANotationsByDialect[dialectStorageKey(for: "AmE")]
            ?? generatedIPANotationsByDialect[dialectStorageKey(for: "BrE")]
            ?? generatedIPANotationsByDialect.values.first
    }

    var generatedIPANotationsByDialect: [String: String] {
        get { aiArtifacts.generatedIPANotationsByDialect }
        set { aiArtifacts.generatedIPANotationsByDialect = newValue }
    }

    var generatedStressSyllablesByDialect: [String: String] {
        get { aiArtifacts.generatedStressSyllablesByDialect }
        set { aiArtifacts.generatedStressSyllablesByDialect = newValue }
    }

    func generatedStressSyllables(for dialect: String?) -> String? {
        generatedStressSyllablesByDialect[dialectStorageKey(for: dialect)]
    }

    var preferredGeneratedStressSyllables: String? {
        generatedStressSyllablesByDialect[dialectStorageKey(for: "AmE")]
            ?? generatedStressSyllablesByDialect[dialectStorageKey(for: "BrE")]
            ?? generatedStressSyllablesByDialect.values.first
    }

    func dialectStorageKey(for dialect: String?) -> String {
        let trimmed = dialect?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed! : "default"
    }

    var isReady: Bool {
        lookupResult != nil
    }

    var hasAcceptedRecallCard: Bool {
        !aiAcceptedRecallCardDrafts.isEmpty
    }

    private func normalizeExampleArtifact(_ artifact: ExampleSentenceArtifact) -> ExampleSentenceArtifact? {
        let normalized = ExampleSentenceArtifact(
            text: artifact.text,
            translation: artifact.translation,
            note: artifact.note,
            anchor: artifact.anchor
        )
        return normalized.text.isEmpty ? nil : normalized
    }

    init(
        id: UUID = UUID(),
        word: String,
        sourceForm: String? = nil,
        inflectionKind: InflectionKind? = nil,
        expectedPartOfSpeech: PartOfSpeech? = nil,
        lookupState: LookupState = .pending,
        audioData: Data? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastRefreshedAt: Date? = nil
    ) {
        self.id = id
        self.word = word.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceForm = sourceForm?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.inflectionKind = inflectionKind
        self.expectedPartOfSpeech = expectedPartOfSpeech
        self.lookupState = lookupState
        self.audioData = audioData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRefreshedAt = lastRefreshedAt
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array {
    var nilIfEmpty: Self? {
        isEmpty ? nil : self
    }
}
