import DictKitSystemDictionary
import DictKitAnkiExport
import Foundation

extension PersistedWordRecord {
    var word: String {
        displayWord
    }

    init(item: WordItem) {
        self.init(
            id: item.id,
            displayWord: item.word,
            normalizedWord: item.normalizedWord,
            sourceForm: item.sourceForm,
            inflectionKind: item.inflectionKind,
            expectedPartOfSpeech: item.expectedPartOfSpeech,
            lookupState: PersistedLookupState(item.lookupState),
            audioData: item.audioData,
            createdAt: item.createdAt,
            updatedAt: item.updatedAt,
            lastRefreshedAt: item.lastRefreshedAt,
            aiArtifacts: item.aiArtifacts
        )
    }

    func makeWordItem() -> WordItem {
        let item = WordItem(
            id: id,
            word: displayWord,
            sourceForm: sourceForm,
            inflectionKind: inflectionKind,
            expectedPartOfSpeech: expectedPartOfSpeech,
            lookupState: lookupState.restoredLookupState,
            audioData: audioData,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastRefreshedAt: lastRefreshedAt
        )
        item.aiArtifacts = aiArtifacts
        return item
    }
}

extension PersistedLookupState {
    init(_ state: LookupState) {
        switch state {
        case .pending:
            self = .pending
        case .loading:
            self = .loading
        case .loaded(let result):
            self = .loaded(result)
        case .failed(let message):
            self = .failed(message)
        }
    }

    var restoredLookupState: LookupState {
        switch self {
        case .pending:
            return .pending
        case .loading:
            return .pending
        case .loaded(let result):
            return .loaded(result)
        case .failed(let message):
            return .failed(message)
        }
    }
}
