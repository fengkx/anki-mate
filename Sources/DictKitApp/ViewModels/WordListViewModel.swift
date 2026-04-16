import DictKit
import DictKitAnkiExport
import DictKitSystemDictionary
import Foundation
import SwiftUI

struct PendingWordDeletion: Identifiable, Equatable {
    let wordID: UUID
    let word: String
    let currentCollectionName: String
    let otherCollectionNames: [String]

    var id: UUID {
        wordID
    }
}

@MainActor
final class WordListViewModel: ObservableObject {
    @Published var collections: [PersistedCollectionRecord] = []
    @Published var currentCollectionID: UUID? {
        didSet {
            guard currentCollectionID != oldValue else { return }
            reloadCurrentWords()
        }
    }
    @Published var words: [WordItem] = []
    @Published var selectedWordID: UUID? {
        didSet {
            guard selectedWordID != oldValue, let id = selectedWordID else { return }
            refreshWordIfNeeded(id: id)
        }
    }
    @Published var inputText: String = ""
    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0
    @Published var exportError: String?
    @Published var collectionEditorErrorMessage: String?
    @Published var showExportDialog: Bool = false
    @Published var showBatchInput: Bool = false
    @Published private(set) var pendingWordDeletion: PendingWordDeletion? = nil

    private let store: any WordListStoring
    private let lookup: @Sendable (String) async throws -> LookupResult
    private let speak: @Sendable (SpeechRequest) async throws -> Void
    private let synthesize: @Sendable (SpeechRequest) async throws -> Data

    private var wordCache: [UUID: WordItem] = [:]
    private var lookupQueue: [LookupJob] = []
    private var isLookupRunning = false
    private var pendingWordDeletionCollectionID: UUID?

    init() {
        let dictionaryClient = SystemDictionaryClient()
        let speechClient = DictionarySpeechClient()
        let store: any WordListStoring
        do {
            store = try WordListStore(databaseURL: Self.defaultDatabaseURL())
        } catch {
            store = NoOpWordListStore()
        }

        self.store = store
        self.lookup = { word in
            let selectedDict = UserDefaults.standard.string(forKey: "selectedDictionary") ?? ""
            let source: DictionaryLookupSource = selectedDict.isEmpty
                ? .automatic
                : .privateHTML(dictionaryName: selectedDict)
            return try dictionaryClient.lookup(word, source: source)
        }
        self.speak = { request in
            try await speechClient.speak(request)
        }
        self.synthesize = { request in
            let payload = try await speechClient.synthesize(request)
            return payload.audioData
        }

        restoreState()
    }

    init(
        store: any WordListStoring,
        lookup: @escaping @Sendable (String) async throws -> LookupResult,
        speak: @escaping @Sendable (SpeechRequest) async throws -> Void,
        synthesize: @escaping @Sendable (SpeechRequest) async throws -> Data
    ) throws {
        self.store = store
        self.lookup = lookup
        self.speak = speak
        self.synthesize = synthesize
        try restoreStateFromStore()
    }

    var currentCollection: PersistedCollectionRecord? {
        guard let id = currentCollectionID else { return nil }
        return collections.first { $0.id == id }
    }

    var selectedWord: WordItem? {
        guard let id = selectedWordID else { return nil }
        return wordCache[id]
    }

    var readyCount: Int {
        words.filter(\.isReady).count
    }

    var wordsColumnTitle: String {
        currentCollection?.name ?? "Words"
    }

    var wordsColumnSummary: String {
        "\(readyCount) of \(words.count) ready"
    }

    var canDeleteSelectedWord: Bool {
        selectedWord != nil
    }

    var canDeleteCurrentCollection: Bool {
        collections.count > 1 && currentCollection != nil
    }

    var canRenameCurrentCollection: Bool {
        currentCollection != nil
    }

    var canExportCollections: Bool {
        !collections.isEmpty && !isExporting
    }

    func exportableWordCount(for collectionID: UUID) -> Int {
        ((try? store.loadWords(in: collectionID)) ?? []).filter { record in
            if let item = wordCache[record.id] {
                return item.isReady
            }
            if case .loaded = record.lookupState {
                return true
            }
            return false
        }.count
    }

    func selectCollection(id: UUID) {
        currentCollectionID = id
    }

    func createCollection(named name: String) -> Bool {
        collectionEditorErrorMessage = nil
        do {
            let record = try store.createCollection(name: name, deckName: nil)
            collections.append(record)
            currentCollectionID = record.id
            collectionEditorErrorMessage = nil
            return true
        } catch {
            collectionEditorErrorMessage = error.localizedDescription
            return false
        }
    }

    func renameCurrentCollection(to name: String) -> Bool {
        guard let currentCollection else { return false }
        collectionEditorErrorMessage = nil
        do {
            let updated = try store.renameCollection(id: currentCollection.id, name: name, deckName: nil)
            collections = collections.map { $0.id == updated.id ? updated : $0 }
            collectionEditorErrorMessage = nil
            return true
        } catch {
            collectionEditorErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteCurrentCollection() {
        guard let currentCollection else { return }
        try? store.deleteCollection(id: currentCollection.id)
        restoreState()
    }

    func defaultExportCollectionIDs() -> Set<UUID> {
        if let currentCollectionID {
            return [currentCollectionID]
        }
        return Set(collections.map(\.id))
    }

    // MARK: - Word Management

    func addWord(_ text: String) {
        guard let currentCollectionID else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let normalizedWord = WordListStore.normalizedWord(for: trimmed)
        guard !words.contains(where: { $0.normalizedWord == normalizedWord }) else { return }

        let now = Date()
        let item = WordItem(word: trimmed, createdAt: now, updatedAt: now)
        do {
            let result = try store.upsertWord(PersistedWordRecord(item: item), into: currentCollectionID)
            upsertCachedWord(result.record)
            reloadCurrentWords()
            guard result.insertedWord else { return }
            enqueueLookup(id: result.record.id, mode: .initial)
        } catch {
            return
        }
    }

    func addWords(from text: String) {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for line in lines {
            addWord(line)
        }
    }

    func removeWords(at offsets: IndexSet) {
        guard let firstIndex = offsets.first, words.indices.contains(firstIndex) else { return }
        requestDelete(words[firstIndex].id)
    }

    func removeWord(_ item: WordItem) {
        requestDelete(item.id)
    }

    func deleteSelectedWord() {
        guard let item = selectedWord else { return }
        requestDelete(item.id)
    }

    func requestDelete(_ wordID: UUID) {
        guard let currentCollection else { return }
        guard let currentWords = try? store.loadWords(in: currentCollection.id),
              let currentWord = currentWords.first(where: { $0.id == wordID }) else {
            clearPendingDeletionState()
            return
        }
        let word = currentWord.word

        let otherCollectionNames = collections.compactMap { collection -> String? in
            guard collection.id != currentCollection.id else { return nil }
            guard let records = try? store.loadWords(in: collection.id) else { return nil }
            return records.contains(where: { $0.id == wordID }) ? collection.name : nil
        }

        pendingWordDeletion = PendingWordDeletion(
            wordID: wordID,
            word: word,
            currentCollectionName: currentCollection.name,
            otherCollectionNames: otherCollectionNames
        )
        pendingWordDeletionCollectionID = currentCollection.id
    }

    func cancelPendingWordDeletion() {
        clearPendingDeletionState()
    }

    func confirmRemovePendingWordFromCurrentCollection() {
        guard let pendingWordDeletion, let pendingWordDeletionCollectionID else { return }
        do {
            try store.removeWord(id: pendingWordDeletion.wordID, from: pendingWordDeletionCollectionID)
            clearPendingDeletionState()
            syncCacheAndReload()
        } catch {
            syncCacheAndReload()
            rebuildPendingDeletionState(for: pendingWordDeletion.wordID)
        }
    }

    func confirmDeletePendingWordEverywhere() {
        guard let pendingWordDeletion else { return }
        do {
            for collection in collections {
                try store.removeWord(id: pendingWordDeletion.wordID, from: collection.id)
            }
            clearPendingDeletionState()
            syncCacheAndReload()
        } catch {
            syncCacheAndReload()
            rebuildPendingDeletionState(for: pendingWordDeletion.wordID)
        }
    }

    // MARK: - Serialized Lookup Queue

    func retryLookup(_ item: WordItem) {
        item.lookupState = .pending
        persist(item)
        enqueueLookup(id: item.id, mode: .retry)
    }

    private func enqueueLookup(id: UUID, mode: LookupMode) {
        guard let item = wordCache[id] else { return }
        switch mode {
        case .initial, .retry:
            item.lookupState = .loading
            item.refreshErrorMessage = nil
            persist(item)
        case .refresh:
            guard item.lookupResult != nil else { return }
            guard !item.isRefreshing, !lookupQueue.contains(where: { $0.id == id && $0.mode == .refresh }) else { return }
            item.isRefreshing = true
            item.refreshErrorMessage = nil
        }
        lookupQueue.append(LookupJob(id: id, mode: mode))
        processNextLookup()
    }

    private func processNextLookup() {
        guard !isLookupRunning, let job = lookupQueue.first else { return }
        lookupQueue.removeFirst()
        isLookupRunning = true
        guard let item = wordCache[job.id] else {
            isLookupRunning = false
            processNextLookup()
            return
        }
        let cachedResult = item.lookupResult

        Task {
            do {
                let result = try await lookup(item.word)
                await MainActor.run {
                    self.handleLookupSuccess(result, for: item, mode: job.mode, cachedResult: cachedResult)
                }
            } catch {
                await MainActor.run {
                    self.handleLookupFailure(error, for: item, mode: job.mode, cachedResult: cachedResult)
                }
            }
            await MainActor.run {
                self.isLookupRunning = false
                self.processNextLookup()
            }
        }
    }

    // MARK: - Speech

    private func makeSpeechRequest(for item: WordItem) -> SpeechRequest? {
        guard let result = item.lookupResult else { return nil }
        let pronunciation = result.entries.first.flatMap { entry -> Pronunciation? in
            entry.pronunciations.first ?? entry.lexicalEntries.first?.pronunciations.first
        }
        return SpeechRequest(
            text: item.word,
            pronunciation: pronunciation,
            sourceLabel: "dictionary"
        )
    }

    func playPronunciation(for item: WordItem) async {
        guard let request = makeSpeechRequest(for: item) else { return }
        do {
            try await speak(request)
        } catch {
            // Silently fail for playback
        }
    }

    func playPronunciation(for item: WordItem, pronunciation: Pronunciation) async {
        let request = SpeechRequest(
            text: item.word,
            pronunciation: pronunciation,
            sourceLabel: "dictionary"
        )
        do {
            try await speak(request)
        } catch {
            // Silently fail for playback
        }
    }

    func synthesizeAudio(for item: WordItem) async {
        guard item.audioData == nil, !item.isSynthesizingAudio else { return }
        item.isSynthesizingAudio = true
        defer { item.isSynthesizingAudio = false }

        guard let request = makeSpeechRequest(for: item) else { return }
        do {
            item.audioData = try await synthesize(request)
            touch(item)
            persist(item)
        } catch {
            // Audio synthesis failure is non-fatal
        }
    }

    func waitForIdle() async {
        while isLookupRunning || !lookupQueue.isEmpty || wordCache.values.contains(where: { $0.isRefreshing }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Export

    func exportToAnki() {
        exportCollections(defaultExportCollectionIDs())
    }

    func exportCollections(_ collectionIDs: Set<UUID>) {
        let selection = collectionIDs.isEmpty ? defaultExportCollectionIDs() : collectionIDs
        guard !selection.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "DictKit Vocabulary.apkg"
        panel.allowedContentTypes = [.init(filenameExtension: "apkg")!]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            isExporting = true
            exportProgress = 0
            exportError = nil

            do {
                let selectedCollections = collections.filter { selection.contains($0.id) }
                let recordsByCollection = selectedCollections.map { collection in
                    (collection, (try? store.loadWords(in: collection.id)) ?? [])
                }
                let uniqueWordIDs = Array(Set(recordsByCollection.flatMap { $0.1.map(\.id) }))
                let total = Double(uniqueWordIDs.count)

                for (i, wordID) in uniqueWordIDs.enumerated() {
                    guard let item = wordCache[wordID], item.audioData == nil, item.isReady else {
                        exportProgress = Double(i + 1) / max(total, 1) * 0.5
                        continue
                    }
                        await synthesizeAudio(for: item)
                    exportProgress = Double(i + 1) / max(total, 1) * 0.5
                }

                let decks: [AnkiExporter.ExportDeck] = recordsByCollection.compactMap { collection, records in
                    let inputs: [AnkiExporter.ExportInput] = records.compactMap { record in
                        guard let item = wordCache[record.id], let result = item.lookupResult else { return nil }
                        return AnkiExporter.ExportInput(
                            word: item.word,
                            lookupResult: result,
                            audioData: item.audioData
                        )
                    }
                    guard !inputs.isEmpty else { return nil }
                    return AnkiExporter.ExportDeck(deckName: collection.ankiDeckName, words: inputs)
                }

                let result = try AnkiExporter.export(
                    decks: decks,
                    to: url
                )

                exportProgress = 1.0
                if !result.warnings.isEmpty {
                    exportError = "Exported \(result.cardCount) cards with warnings:\n" +
                        result.warnings.joined(separator: "\n")
                }
            } catch {
                exportError = error.localizedDescription
            }

            isExporting = false
        }
    }

    private func refreshWordIfNeeded(id: UUID) {
        enqueueLookup(id: id, mode: .refresh)
    }

    private func handleLookupSuccess(
        _ result: LookupResult,
        for item: WordItem,
        mode: LookupMode,
        cachedResult: LookupResult?
    ) {
        let resultChanged = cachedResult != result
        item.lookupState = .loaded(result)
        item.refreshErrorMessage = nil
        item.isRefreshing = false
        if mode == .refresh {
            item.lastRefreshedAt = Date()
        }
        if mode == .refresh, resultChanged {
            item.audioData = nil
        }
        touch(item)
        persist(item)
    }

    private func handleLookupFailure(
        _ error: Error,
        for item: WordItem,
        mode: LookupMode,
        cachedResult: LookupResult?
    ) {
        item.isRefreshing = false
        let message = error.localizedDescription
        switch mode {
        case .refresh where cachedResult != nil:
            item.refreshErrorMessage = message
        case .initial, .retry, .refresh:
            item.lookupState = .failed(message)
            touch(item)
            persist(item)
        }
    }

    private func restoreState() {
        do {
            try restoreStateFromStore()
        } catch {
            collections = []
            currentCollectionID = nil
            words = []
            wordCache = [:]
        }
    }

    private func restoreStateFromStore() throws {
        let collections = try store.loadCollections()
        let allWords = try store.loadAllWords()
        self.collections = collections
        self.wordCache = Dictionary(uniqueKeysWithValues: allWords.map { ($0.id, $0.makeWordItem()) })
        if let currentCollectionID, collections.contains(where: { $0.id == currentCollectionID }) {
            self.currentCollectionID = currentCollectionID
        } else {
            self.currentCollectionID = collections.first?.id
        }
        reloadCurrentWords()
    }

    private func reloadCurrentWords() {
        guard let currentCollectionID else {
            words = []
            selectedWordID = nil
            reconcilePendingDeletionState()
            return
        }
        let records = (try? store.loadWords(in: currentCollectionID)) ?? []
        for record in records {
            upsertCachedWord(record)
        }
        words = records.compactMap { wordCache[$0.id] }
        if let selectedWordID, !words.contains(where: { $0.id == selectedWordID }) {
            self.selectedWordID = nil
        }
        reconcilePendingDeletionState()
    }

    private func syncCacheAndReload() {
        let allWords = (try? store.loadAllWords()) ?? []
        let ids = Set(allWords.map(\.id))
        wordCache = wordCache.filter { ids.contains($0.key) }
        for record in allWords {
            upsertCachedWord(record)
        }
        reloadCurrentWords()
    }

    private func upsertCachedWord(_ record: PersistedWordRecord) {
        if let existing = wordCache[record.id] {
            existing.lookupState = record.lookupState.restoredLookupState
            existing.audioData = record.audioData
            existing.updatedAt = record.updatedAt
            existing.lastRefreshedAt = record.lastRefreshedAt
        } else {
            wordCache[record.id] = record.makeWordItem()
        }
    }

    private func touch(_ item: WordItem) {
        item.updatedAt = Date()
    }

    private func persist(_ item: WordItem) {
        try? store.saveWord(PersistedWordRecord(item: item))
    }

    private func reconcilePendingDeletionState() {
        guard let pendingWordDeletion else { return }
        rebuildPendingDeletionState(
            for: pendingWordDeletion.wordID,
            preferredCollectionID: pendingWordDeletionCollectionID
        )
    }

    private func rebuildPendingDeletionState(for wordID: UUID, preferredCollectionID: UUID? = nil) {
        let remainingMemberships: [(collection: PersistedCollectionRecord, record: PersistedWordRecord)] = collections.compactMap { collection in
            guard let records = try? store.loadWords(in: collection.id),
                  let record = records.first(where: { $0.id == wordID }) else { return nil }
            return (collection, record)
        }

        guard !remainingMemberships.isEmpty else {
            clearPendingDeletionState()
            return
        }

        let sourceMembership: (collection: PersistedCollectionRecord, record: PersistedWordRecord)
        if let preferredCollectionID,
           let preferredMembership = remainingMemberships.first(where: { $0.collection.id == preferredCollectionID }) {
            sourceMembership = preferredMembership
        } else if let currentCollectionID,
                  let preferredMembership = remainingMemberships.first(where: { $0.collection.id == currentCollectionID }) {
            sourceMembership = preferredMembership
        } else {
            sourceMembership = remainingMemberships[0]
        }

        pendingWordDeletion = PendingWordDeletion(
            wordID: wordID,
            word: sourceMembership.record.word,
            currentCollectionName: sourceMembership.collection.name,
            otherCollectionNames: remainingMemberships
                .map(\.collection)
                .filter { $0.id != sourceMembership.collection.id }
                .map(\.name)
        )
        pendingWordDeletionCollectionID = sourceMembership.collection.id
    }

    private func clearPendingDeletionState() {
        pendingWordDeletion = nil
        pendingWordDeletionCollectionID = nil
    }

    private static func defaultDatabaseURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("DictKit", isDirectory: true)
            .appendingPathComponent("word-list.sqlite3")
    }
}

private struct LookupJob: Equatable {
    let id: UUID
    let mode: LookupMode
}

private enum LookupMode: Equatable {
    case initial
    case retry
    case refresh
}
