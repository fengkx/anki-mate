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

    // AI suggestion layer (suggested -> accepted)
    @Published var aiSuggestedExampleSentences: [String] = []
    @Published var aiAcceptedExampleSentences: [String] = []
    @Published var aiSuggestedDefinitionNote: String?
    @Published var aiAcceptedDefinitionNote: String?
    @Published var isGeneratingAI: Bool = false

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
