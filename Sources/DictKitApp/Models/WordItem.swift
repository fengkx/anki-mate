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

    var aiSuggestedExampleSentences: [String] {
        get { aiArtifacts.suggestedExampleSentences }
        set {
            aiArtifacts.exampleSentences.suggested = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ExampleSentenceArtifact(text: trimmed)
            }.nilIfEmpty
        }
    }

    var aiAcceptedExampleSentences: [String] {
        get { aiArtifacts.acceptedExampleSentences }
        set {
            aiArtifacts.exampleSentences.accepted = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ExampleSentenceArtifact(text: trimmed)
            }.nilIfEmpty
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
        set { aiArtifacts.recallCardDrafts.accepted = newValue.nilIfEmpty }
    }

    var aiSuggestedPitfalls: [String] {
        get { aiArtifacts.suggestedPitfallTexts }
        set {
            aiArtifacts.pitfalls.suggested = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return PitfallArtifact(text: trimmed)
            }.nilIfEmpty
        }
    }

    var aiAcceptedPitfalls: [String] {
        get { aiArtifacts.acceptedPitfallTexts }
        set {
            aiArtifacts.pitfalls.accepted = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return PitfallArtifact(text: trimmed)
            }.nilIfEmpty
        }
    }

    var aiSuggestedMnemonics: [String] {
        get { aiArtifacts.suggestedMnemonicTexts }
        set {
            aiArtifacts.mnemonics.suggested = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return MnemonicArtifact(text: trimmed)
            }.nilIfEmpty
        }
    }

    var aiAcceptedMnemonics: [String] {
        get { aiArtifacts.acceptedMnemonicTexts }
        set {
            aiArtifacts.mnemonics.accepted = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return MnemonicArtifact(text: trimmed)
            }.nilIfEmpty
        }
    }

    var aiSuggestedCollocations: [String] {
        get { aiArtifacts.suggestedCollocationPhrases }
        set {
            aiArtifacts.collocations.suggested = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return CollocationArtifact(phrase: trimmed)
            }.nilIfEmpty
        }
    }

    var aiAcceptedCollocations: [String] {
        get { aiArtifacts.acceptedCollocationPhrases }
        set {
            aiArtifacts.collocations.accepted = newValue.compactMap {
                let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return CollocationArtifact(phrase: trimmed)
            }.nilIfEmpty
        }
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
        guard let result = lookupResult else { return "" }
        return AnkiFieldFormatter.phonetic(from: result)
    }

    var phoneticsByDialect: [(dialect: String, ipa: String, pronunciation: Pronunciation)] {
        guard let result = lookupResult else { return [] }
        var seen = Set<String>()
        var items: [(dialect: String, ipa: String, pronunciation: Pronunciation)] = []
        for entry in result.entries {
            let allPronunciations = entry.pronunciations.isEmpty
                ? entry.lexicalEntries.flatMap(\.pronunciations)
                : entry.pronunciations
            for p in allPronunciations {
                let ipa = p.ipa.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ipa.isEmpty else { continue }
                let dialect = p.dialect ?? ""
                let key = "\(dialect):\(ipa)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                items.append((dialect: dialect, ipa: ipa, pronunciation: p))
            }
        }
        return items
    }

    var isReady: Bool {
        lookupResult != nil
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
