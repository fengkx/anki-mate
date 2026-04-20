import DictKit
import DictKitAnkiExport
import DictKitSystemDictionary
import AnkiMateShared
import Foundation
import SwiftUI
import Combine

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
            guard selectedWordID != oldValue else { return }
        }
    }
    @Published var inputText: String = ""
    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0
    @Published var exportError: String?
    @Published var storeErrorMessage: String?
    @Published var collectionEditorErrorMessage: String?
    @Published var showExportDialog: Bool = false
    @Published var showBatchInput: Bool = false

    private let store: any WordListStoring
    /// Exposed for sync engine. Returns nil if the store is a NoOpWordListStore.
    var wordListStore: WordListStore? { store as? WordListStore }
    /// Called when data is mutated (add/remove/update word or collection).
    var onDataChanged: (() -> Void)?

    private func notifyDataChanged() {
        onDataChanged?()
    }
    private let rawLookup: @Sendable (String, DictionaryLookupSource) async throws -> LookupResult
    private let resolvedLookupService: ResolvedLookupService
    private let speak: @Sendable (SpeechRequest) async throws -> Void
    private let synthesize: @Sendable (SpeechRequest) async throws -> Data

    private var wordCache: [UUID: WordItem] = [:]
    private var wordChangeCancellables: [UUID: AnyCancellable] = [:]
    private var lookupQueue: [LookupJob] = []
    private var isLookupRunning = false

    init() {
        let dictionaryClient = SystemDictionaryClient()
        let speechClient = DictionarySpeechClient()
        let store: any WordListStoring
        let storeErrorMessage: String?
        do {
            store = try WordListStore(databaseURL: Self.defaultDatabaseURL())
            storeErrorMessage = nil
        } catch {
            store = NoOpWordListStore()
            storeErrorMessage = "Storage initialization failed: \(error.localizedDescription)"
        }

        self.store = store
        self.storeErrorMessage = storeErrorMessage
        self.rawLookup = { word, source in
            try dictionaryClient.lookup(word, source: source)
        }
        self.resolvedLookupService = ResolvedLookupService(lookup: self.rawLookup)
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
        storeErrorMessage: String? = nil,
        lookup: @escaping @Sendable (String, DictionaryLookupSource) async throws -> LookupResult,
        speak: @escaping @Sendable (SpeechRequest) async throws -> Void,
        synthesize: @escaping @Sendable (SpeechRequest) async throws -> Data
    ) throws {
        self.store = store
        self.storeErrorMessage = storeErrorMessage
        self.rawLookup = lookup
        self.resolvedLookupService = ResolvedLookupService(lookup: lookup)
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

    var canExportCurrentCollection: Bool {
        currentCollection != nil && !isExporting
    }

    func searchableWordsInCurrentCollection() -> [WordItem] {
        words
    }

    func wordItem(for id: UUID) -> WordItem? {
        wordCache[id]
    }

    func selectWord(id: UUID) {
        selectedWordID = id
    }

    func refreshSelectedWordIfNeeded() {
        guard let id = selectedWordID else { return }
        refreshWordIfNeeded(id: id)
    }

    func containsNormalizedWordInCurrentCollection(_ text: String) -> Bool {
        let normalizedWord = WordListStore.normalizedWord(for: text)
        return words.contains(where: { $0.normalizedWord == normalizedWord })
    }

    func validateWordCanBeAdded(_ query: String) async -> WordAddValidationResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        let normalizedWord = WordListStore.normalizedWord(for: trimmed)
        if let existing = words.first(where: { $0.normalizedWord == normalizedWord }) {
            return .duplicateExistingWord(existingWordID: existing.id)
        }

        guard let currentCollection else {
            return .failed("No collection selected")
        }

        do {
            let resolved = try await resolvedLookupService.resolve(trimmed, dictionaryName: currentCollection.dictionaryName)
            return .dictionaryMatch(canonicalWord: resolved.word)
        } catch LookupError.notFound {
            return .notFound
        } catch {
            return .failed(error.localizedDescription)
        }
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

    func dismissStoreError() {
        storeErrorMessage = nil
    }

    func reloadFromStore() {
        do {
            try restoreStateFromStore()
            storeErrorMessage = nil
        } catch {
            storeErrorMessage = "Storage reload failed: \(error.localizedDescription)"
        }
    }

    func createCollection(named name: String) -> Bool {
        createCollection(
            using: .defaults(forCollectionName: name)
        )
    }

    func createCollection(using form: CollectionEditorFormData) -> Bool {
        collectionEditorErrorMessage = nil
        do {
            let record = try store.createCollection(
                name: form.collectionName,
                exportSettings: form.exportSettings,
                dictionaryName: form.dictionaryName
            )
            collections.append(record)
            currentCollectionID = record.id
            collectionEditorErrorMessage = nil
            notifyDataChanged()
            return true
        } catch {
            collectionEditorErrorMessage = error.localizedDescription
            return false
        }
    }

    func renameCurrentCollection(to name: String) -> Bool {
        renameCurrentCollection(
            using: CollectionEditorFormData(
                collectionName: name,
                deckDescription: currentCollection?.ankiDeckDescription ?? "",
                dictionaryName: currentCollection?.dictionaryName ?? ""
            )
        )
    }

    func renameCurrentCollection(using form: CollectionEditorFormData) -> Bool {
        guard let currentCollection else { return false }
        collectionEditorErrorMessage = nil
        do {
            let updated = try store.renameCollection(
                id: currentCollection.id,
                name: form.collectionName,
                exportSettings: form.exportSettings,
                dictionaryName: form.dictionaryName
            )
            collections = collections.map { $0.id == updated.id ? updated : $0 }
            collectionEditorErrorMessage = nil
            notifyDataChanged()
            return true
        } catch {
            collectionEditorErrorMessage = error.localizedDescription
            return false
        }
    }

    func deleteCurrentCollection() {
        guard let currentCollection else { return }
        try? store.deleteCollection(id: currentCollection.id)
        notifyDataChanged()
        restoreState()
    }

    func collectionEditorForm(for mode: CollectionEditorMode) -> CollectionEditorFormData {
        switch mode {
        case .create:
            return .defaults(forCollectionName: "")
        case .rename, .dictionary:
            guard let currentCollection else {
                return .defaults(forCollectionName: "")
            }
            return CollectionEditorFormData(
                collectionName: currentCollection.name,
                deckDescription: currentCollection.ankiDeckDescription,
                dictionaryName: currentCollection.dictionaryName
            )
        }
    }

    func defaultExportRequest() -> CollectionExportRequest? {
        guard let currentCollection else { return nil }
        return CollectionExportRequest(
            collectionID: currentCollection.id,
            deckDescription: currentCollection.ankiDeckDescription
        )
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
            notifyDataChanged()
            guard result.insertedWord else { return }
            enqueueLookup(id: result.record.id, mode: .initial, collectionID: currentCollectionID)
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
        deleteWord(id: words[firstIndex].id)
    }

    func removeWord(_ item: WordItem) {
        deleteWord(id: item.id)
    }

    func deleteSelectedWord() {
        guard let item = selectedWord else { return }
        deleteWord(id: item.id)
    }

    // MARK: - Serialized Lookup Queue

    func retryLookup(_ item: WordItem) {
        guard let currentCollectionID else { return }
        item.lookupState = .pending
        persist(item)
        enqueueLookup(id: item.id, mode: .retry, collectionID: currentCollectionID)
    }

    private func enqueueLookup(id: UUID, mode: LookupMode, collectionID: UUID) {
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
        lookupQueue.append(LookupJob(id: id, mode: mode, collectionID: collectionID))
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
        guard let collection = collections.first(where: { $0.id == job.collectionID }) else {
            isLookupRunning = false
            processNextLookup()
            return
        }
        let cachedResult = item.lookupResult

        Task {
            do {
                let result = try await resolvedLookupService.resolve(item.word, dictionaryName: collection.dictionaryName)
                await MainActor.run {
                    self.handleLookupSuccess(result, for: item, collectionID: job.collectionID, mode: job.mode, cachedResult: cachedResult)
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

    private func persistAudio(_ audioData: Data, for item: WordItem) {
        item.audioData = audioData
        touch(item)
        persist(item)
    }

    private func refreshSavedAudio(for item: WordItem, request: SpeechRequest) async {
        do {
            let audioData = try await synthesize(request)
            persistAudio(audioData, for: item)
        } catch {
            // Audio synthesis failure is non-fatal
        }
    }

    func playPronunciation(for item: WordItem) async {
        guard let request = makeSpeechRequest(for: item) else { return }
        if item.audioData == nil {
            item.isSynthesizingAudio = true
            defer { item.isSynthesizingAudio = false }
            await refreshSavedAudio(for: item, request: request)
        }
        do {
            try await speak(request)
        } catch {
            // Silently fail for playback
        }
    }

    func refreshPronunciationAudio(for item: WordItem) async {
        guard let request = makeSpeechRequest(for: item) else { return }
        item.isSynthesizingAudio = true
        defer { item.isSynthesizingAudio = false }
        await refreshSavedAudio(for: item, request: request)
    }

    func playPronunciation(for item: WordItem, pronunciation: Pronunciation) async {
        let request = SpeechRequest(
            text: item.word,
            pronunciation: pronunciation,
            sourceLabel: "dictionary"
        )
        if item.audioData == nil {
            item.isSynthesizingAudio = true
            defer { item.isSynthesizingAudio = false }
            await refreshSavedAudio(for: item, request: request)
        }
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
        await refreshSavedAudio(for: item, request: request)
    }

    func saveAISuggestedExampleSentences(_ sentences: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedExampleSentences = sentences
        }
    }

    func saveAISuggestedExampleArtifacts(_ artifacts: [ExampleSentenceArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedExampleArtifacts = artifacts
        }
    }

    func saveAIAcceptedExampleSentences(_ sentences: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedExampleSentences = sentences
        }
    }

    func saveAIAcceptedExampleArtifacts(_ artifacts: [ExampleSentenceArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedExampleArtifacts = artifacts
        }
    }

    func saveAISuggestedDefinitionNote(_ note: String?, for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedDefinitionNote = note
        }
    }

    func saveAIAcceptedDefinitionNote(_ note: String?, for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedDefinitionNote = note
        }
    }

    func saveAISuggestedRecallCardDrafts(_ drafts: [RecallCardDraft], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedRecallCardDrafts = drafts
        }
    }

    func saveAIAcceptedRecallCardDrafts(_ drafts: [RecallCardDraft], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedRecallCardDrafts = drafts
        }
    }

    func saveAISuggestedPitfalls(_ values: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedPitfalls = values
        }
    }

    func saveAISuggestedPitfallArtifacts(_ artifacts: [PitfallArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedPitfallArtifacts = artifacts
        }
    }

    func saveAIAcceptedPitfalls(_ values: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedPitfalls = values
        }
    }

    func saveAIAcceptedPitfallArtifacts(_ artifacts: [PitfallArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedPitfallArtifacts = artifacts
        }
    }

    func saveAISuggestedMnemonics(_ values: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedMnemonics = values
        }
    }

    func saveAISuggestedMnemonicArtifacts(_ artifacts: [MnemonicArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedMnemonicArtifacts = artifacts
        }
    }

    func saveAIAcceptedMnemonics(_ values: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedMnemonics = values
        }
    }

    func saveAIAcceptedMnemonicArtifacts(_ artifacts: [MnemonicArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedMnemonicArtifacts = artifacts
        }
    }

    func saveAISuggestedCollocations(_ values: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedCollocations = values
        }
    }

    func saveAISuggestedCollocationArtifacts(_ artifacts: [CollocationArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiSuggestedCollocationArtifacts = artifacts
        }
    }

    func saveAIAcceptedCollocations(_ values: [String], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedCollocations = values
        }
    }

    func saveAIAcceptedCollocationArtifacts(_ artifacts: [CollocationArtifact], for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiAcceptedCollocationArtifacts = artifacts
        }
    }

    func saveLearningAidSelection(
        _ selection: LearningAidSectionSelection?,
        for section: LearningAidSelectionSection,
        item: WordItem
    ) {
        persistAIArtifactUpdate(for: item) {
            item.aiArtifacts.updateLearningAidSelection(for: section, value: selection)
        }
    }

    func saveAIArtifacts(_ artifacts: AIArtifacts, for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            item.aiArtifacts = artifacts
        }
    }

    func saveGeneratedIPA(_ value: String, dialect: String?, for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            var saved = item.generatedIPANotationsByDialect
            saved[item.dialectStorageKey(for: dialect)] = value
            item.generatedIPANotationsByDialect = saved
        }
    }

    func saveGeneratedStressSyllables(_ value: String, dialect: String?, for item: WordItem) {
        persistAIArtifactUpdate(for: item) {
            var saved = item.generatedStressSyllablesByDialect
            saved[item.dialectStorageKey(for: dialect)] = value
            item.generatedStressSyllablesByDialect = saved
        }
    }

    func waitForIdle() async {
        while isLookupRunning || !lookupQueue.isEmpty || wordCache.values.contains(where: { $0.isRefreshing }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Export

    func exportToAnki() {
        guard let request = defaultExportRequest() else { return }
        exportCollection(request)
    }

    func exportCollection(_ request: CollectionExportRequest) {
        guard let collection = collections.first(where: { $0.id == request.collectionID }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizedPackageFilenameStem(collection.name, fallback: "Collection")).apkg"
        panel.allowedContentTypes = [.init(filenameExtension: "apkg")!]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            isExporting = true
            exportProgress = 0
            exportError = nil

            do {
                let records = (try? store.loadWords(in: collection.id)) ?? []
                let total = Double(records.count)

                for (i, wordID) in records.map(\.id).enumerated() {
                    guard let item = wordCache[wordID], item.audioData == nil, item.isReady else {
                        exportProgress = Double(i + 1) / max(total, 1) * 0.5
                        continue
                    }
                    await synthesizeAudio(for: item)
                    exportProgress = Double(i + 1) / max(total, 1) * 0.5
                }

                let inputs: [AnkiExporter.ExportInput] = records.compactMap { record in
                    guard let item = wordCache[record.id], let result = item.lookupResult else { return nil }
                    return AnkiExporter.ExportInput(
                        word: item.word,
                        lookupResult: result,
                        audioData: item.audioData,
                        aiArtifacts: item.aiArtifacts
                    )
                }
                guard !inputs.isEmpty else {
                    isExporting = false
                    return
                }

                let result = try AnkiExporter.export(
                    decks: [
                        AnkiExporter.ExportDeck(
                            deckName: collection.name,
                            deckDescription: sanitizedDeckDescription(request.deckDescription),
                            words: inputs
                        )
                    ],
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
        guard let currentCollectionID else { return }
        enqueueLookup(id: id, mode: .refresh, collectionID: currentCollectionID)
    }

    private func handleLookupSuccess(
        _ resolved: ResolvedLookup,
        for item: WordItem,
        collectionID: UUID,
        mode: LookupMode,
        cachedResult: LookupResult?
    ) {
        let resultChanged = cachedResult != resolved.lookupResult
        item.word = resolved.word
        item.sourceForm = resolved.sourceForm
        item.inflectionKind = resolved.inflectionKind
        item.expectedPartOfSpeech = resolved.expectedPartOfSpeech
        item.lookupState = .loaded(resolved.lookupResult)
        item.refreshErrorMessage = nil
        item.isRefreshing = false
        if mode == .refresh {
            item.lastRefreshedAt = Date()
        }
        if mode == .refresh, resultChanged {
            item.audioData = nil
        }
        if resolveDuplicateLemma(for: item, collectionID: collectionID) {
            return
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
            wordChangeCancellables = [:]
        }
    }

    private func restoreStateFromStore() throws {
        let collections = try store.loadCollections()
        let allWords = try store.loadAllWords()
        self.collections = collections
        self.wordCache = Dictionary(uniqueKeysWithValues: allWords.map { ($0.id, $0.makeWordItem()) })
        rebindWordObservers()
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
    }

    private func syncCacheAndReload() {
        let allWords = (try? store.loadAllWords()) ?? []
        let ids = Set(allWords.map(\.id))
        wordCache = wordCache.filter { ids.contains($0.key) }
        wordChangeCancellables = wordChangeCancellables.filter { ids.contains($0.key) }
        for record in allWords {
            upsertCachedWord(record)
        }
        reloadCurrentWords()
    }

    private func deleteWord(id: UUID) {
        guard let currentCollectionID else { return }
        do {
            try store.removeWord(id: id, from: currentCollectionID)
            notifyDataChanged()
        } catch {
            syncCacheAndReload()
            return
        }
        syncCacheAndReload()
    }

    private func upsertCachedWord(_ record: PersistedWordRecord) {
        if let existing = wordCache[record.id] {
            existing.word = record.displayWord
            existing.sourceForm = record.sourceForm
            existing.inflectionKind = record.inflectionKind
            existing.expectedPartOfSpeech = record.expectedPartOfSpeech
            existing.lookupState = record.lookupState.restoredLookupState
            existing.audioData = record.audioData
            existing.updatedAt = record.updatedAt
            existing.lastRefreshedAt = record.lastRefreshedAt
            existing.aiArtifacts = record.aiArtifacts
        } else {
            let item = record.makeWordItem()
            wordCache[record.id] = item
            observeWordChanges(for: item)
        }
    }

    private func observeWordChanges(for item: WordItem) {
        guard wordChangeCancellables[item.id] == nil else { return }
        wordChangeCancellables[item.id] = item.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func rebindWordObservers() {
        wordChangeCancellables.removeAll()
        for item in wordCache.values {
            observeWordChanges(for: item)
        }
    }

    private func resolveDuplicateLemma(for item: WordItem, collectionID: UUID) -> Bool {
        guard let currentRecords = try? store.loadWords(in: collectionID) else { return false }
        guard let duplicateID = currentRecords.first(where: {
            $0.id != item.id && $0.normalizedWord == item.normalizedWord
        })?.id else {
            return false
        }

        if let selectedWordID, selectedWordID == item.id {
            self.selectedWordID = duplicateID
        }

        try? store.removeWord(id: item.id, from: collectionID)
        wordCache[item.id] = nil
        wordChangeCancellables[item.id] = nil
        reloadCurrentWords()
        return true
    }

    private func touch(_ item: WordItem) {
        item.updatedAt = Date()
    }

    private func persistAIArtifactUpdate(for item: WordItem, update: () -> Void) {
        update()
        item.aiArtifacts = item.aiArtifacts.normalized()
        touch(item)
        persist(item)
    }

    private func persist(_ item: WordItem) {
        try? store.saveWord(PersistedWordRecord(item: item))
        notifyDataChanged()
    }

    private func sanitizedDeckDescription(_ description: String) -> String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizedPackageFilenameStem(_ stem: String, fallback: String) -> String {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutExtension = trimmed.lowercased().hasSuffix(".apkg")
            ? String(trimmed.dropLast(5))
            : trimmed
        return withoutExtension.isEmpty ? fallback : withoutExtension
    }

    private static func defaultDatabaseURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent(AnkiMateIdentity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("word-list.sqlite3")
    }
}

private struct LookupJob: Equatable {
    let id: UUID
    let mode: LookupMode
    let collectionID: UUID
}

private enum LookupMode: Equatable {
    case initial
    case retry
    case refresh
}

private extension CollectionEditorFormData {
    func withCollectionName(_ name: String) -> CollectionEditorFormData {
        CollectionEditorFormData(
            collectionName: name,
            deckDescription: deckDescription,
            dictionaryName: dictionaryName
        )
    }
}
