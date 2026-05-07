import Foundation

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    struct Actions {
        var openBatchAdd: @MainActor () -> Void
        var openExport: @MainActor () -> Void
        var openNewCollection: @MainActor () -> Void
        var openCollectionSettings: @MainActor () -> Void
        var openWindow: @MainActor (String) -> Void
        var syncNow: @MainActor () async -> Void
    }

    @Published var isPresented = false
    @Published var query = ""
    @Published private(set) var mode: CommandPaletteMode = .words
    @Published private(set) var items: [CommandPaletteItem] = []
    @Published private(set) var highlightedItemID: String?
    @Published private(set) var lookupValidationState: LookupValidationState = .idle

    private let wordListViewModel: WordListViewModel
    private let historyStore: CommandPaletteHistoryStore
    private var actions: Actions?
    private var validationTask: Task<Void, Never>?

    init(
        wordListViewModel: WordListViewModel,
        historyStore: CommandPaletteHistoryStore = CommandPaletteHistoryStore()
    ) {
        self.wordListViewModel = wordListViewModel
        self.historyStore = historyStore
    }

    deinit {
        validationTask?.cancel()
    }

    func configure(actions: Actions) {
        self.actions = actions
    }

    func togglePresentation() {
        isPresented ? dismiss() : present()
    }

    func present() {
        query = ""
        mode = .words
        lookupValidationState = .idle
        highlightedItemID = nil
        isPresented = true
        recomputeItems()
    }

    func dismiss() {
        validationTask?.cancel()
        validationTask = nil
        isPresented = false
        query = ""
        mode = .words
        items = []
        highlightedItemID = nil
        lookupValidationState = .idle
    }

    func updateQuery(_ query: String) {
        self.query = query
        if mode != .collections {
            mode = query.hasPrefix(">") ? .commands : .words
        }
        highlightedItemID = nil
        recomputeItems()
        scheduleValidationIfNeeded()
    }

    func moveSelection(delta: Int) {
        let selectableItems = items.filter(\.isSelectable)
        guard !selectableItems.isEmpty else { return }

        guard let highlightedItemID = self.highlightedItemID,
              let current = selectableItems.firstIndex(where: { $0.id == highlightedItemID }) else {
            self.highlightedItemID = selectableItems.first?.id
            return
        }

        let next = max(0, min(selectableItems.count - 1, current + delta))
        self.highlightedItemID = selectableItems[next].id
    }

    func highlightItem(id: String) {
        guard let item = items.first(where: { $0.id == id }), item.isSelectable else { return }
        highlightedItemID = item.id
    }

    func activateHighlightedItem() {
        guard let highlightedItemID,
              let item = items.first(where: { $0.id == highlightedItemID }) else { return }
        execute(item)
    }

    func addCurrentQueryIfPossible() {
        guard let item = addWordItem else { return }
        execute(.addWord(item))
    }

    func execute(_ item: CommandPaletteItem) {
        switch item {
        case .word(let word):
            wordListViewModel.selectWord(id: word.wordID)
            historyStore.recordWord(word.wordID)
            dismiss()
        case .addWord(let item):
            wordListViewModel.addWord(item.query)
            dismiss()
        case .command(let command):
            historyStore.recordCommand(command.id)
            performCommand(command.id)
        case .collection(let collection):
            wordListViewModel.selectCollection(id: collection.collectionID)
            dismiss()
        case .info:
            break
        }
    }

    func recomputeItems() {
        let nextItems: [CommandPaletteItem]
        switch mode {
        case .words:
            nextItems = buildWordItems()
        case .commands:
            nextItems = buildCommandItems()
        case .collections:
            nextItems = buildCollectionItems()
        }

        items = nextItems
        if let highlightedItemID,
           items.contains(where: { $0.id == highlightedItemID && $0.isSelectable }) {
            return
        }
        highlightedItemID = items.first(where: \.isSelectable)?.id
    }

    var groupedItems: [(CommandPaletteSection, [CommandPaletteItem])] {
        var buckets: [(CommandPaletteSection, [CommandPaletteItem])] = []
        for item in items {
            if let lastIndex = buckets.indices.last, buckets[lastIndex].0 == item.section {
                buckets[lastIndex].1.append(item)
            } else {
                buckets.append((item.section, [item]))
            }
        }
        return buckets
    }

    var canAddCurrentQuery: Bool {
        addWordItem != nil
    }

    var addWordPreview: CommandPaletteAddWordPreview? {
        guard mode == .words else { return nil }

        let trimmedQuery = rawTrimmedQuery
        guard !trimmedQuery.isEmpty else { return nil }

        switch lookupValidationState {
        case .idle:
            return nil
        case .checking(let checkingQuery):
            guard checkingQuery == normalizedQuery else { return nil }
            return CommandPaletteAddWordPreview(
                status: .checking,
                query: trimmedQuery,
                canonicalWord: nil,
                definition: nil,
                message: "Checking dictionary..."
            )
        case .result(let query, let outcome):
            guard query == normalizedQuery else { return nil }
            switch outcome {
            case .dictionaryMatch(let canonicalWord, let definition):
                return CommandPaletteAddWordPreview(
                    status: .readyToAdd,
                    query: trimmedQuery,
                    canonicalWord: canonicalWord,
                    definition: definition,
                    message: "Press Cmd+Enter to add directly"
                )
            case .duplicateExistingWord:
                return CommandPaletteAddWordPreview(
                    status: .duplicateExistingWord,
                    query: trimmedQuery,
                    canonicalWord: nil,
                    definition: nil,
                    message: "Already exists in the current collection"
                )
            case .notFound:
                return CommandPaletteAddWordPreview(
                    status: .notFound,
                    query: trimmedQuery,
                    canonicalWord: nil,
                    definition: nil,
                    message: "No dictionary match found"
                )
            case .failed(let error):
                return CommandPaletteAddWordPreview(
                    status: .failed,
                    query: trimmedQuery,
                    canonicalWord: nil,
                    definition: nil,
                    message: error
                )
            }
        }
    }

    var placeholder: String {
        switch mode {
        case .words:
            return "Search words, or type > for commands"
        case .commands:
            return "Type a command"
        case .collections:
            return "Search collections"
        }
    }

    var footerHint: String {
        switch mode {
        case .words:
            return canAddCurrentQuery
                ? "↑↓ Navigate    Enter Open    Cmd+Enter Add    Esc Close"
                : "↑↓ Navigate    Enter Open    Esc Close"
        case .commands:
            return "↑↓ Navigate    Enter Run    Esc Close"
        case .collections:
            return "↑↓ Navigate    Enter Switch    Esc Close"
        }
    }

    private var addWordItem: CommandPaletteAddWordItem? {
        guard mode == .words else { return nil }
        guard case .result(let query, let outcome) = lookupValidationState else { return nil }
        guard query == normalizedQuery else { return nil }

        if case .dictionaryMatch(let canonicalWord, let definition) = outcome {
            return CommandPaletteAddWordItem(
                query: rawTrimmedQuery,
                canonicalWord: canonicalWord,
                definition: definition
            )
        }
        return nil
    }

    private var rawTrimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        WordListStore.normalizedWord(for: rawTrimmedQuery)
    }

    private func buildWordItems() -> [CommandPaletteItem] {
        guard wordListViewModel.currentCollection != nil else {
            return [
                .info(.init(
                    id: "no-collection",
                    title: "No collection selected",
                    subtitle: "Choose a collection to search or add words",
                    systemImage: "exclamationmark.circle"
                ))
            ]
        }

        let trimmedQuery = rawTrimmedQuery
        var results: [CommandPaletteItem] = []

        if trimmedQuery.isEmpty {
            let history = historyStore.load()
            let recentWords = history.recentWordIDs.compactMap { wordListViewModel.wordItem(for: $0) }
            results.append(contentsOf: recentWords.map { item in
                .word(makeWordItem(from: item, isRecent: true))
            })
            results.append(contentsOf: defaultCommands(limit: 3).map(CommandPaletteItem.command))
            return results
        }

        let matchingWords = wordListViewModel.searchableWordsInCurrentCollection()
            .compactMap { item -> (WordItem, Int)? in
                let fields = [item.word, item.sourceForm, item.phonetic]
                    .compactMap { field -> String? in
                        guard let field else { return nil }
                        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                let bestScore = fields.compactMap { FuzzyMatcher.score(query: trimmedQuery, candidate: $0) }.max()
                guard let bestScore else { return nil }
                var boostedScore = bestScore
                if item.isReady {
                    boostedScore += 10
                }
                return (item, boostedScore)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.word.localizedCaseInsensitiveCompare(rhs.0.word) == .orderedAscending
            }
            .prefix(20)

        results.append(contentsOf: matchingWords.map { CommandPaletteItem.word(makeWordItem(from: $0.0, isRecent: false)) })

        if results.isEmpty {
            results.append(
                .info(.init(
                    id: "no-word-results",
                    title: "No matching word in this collection",
                    subtitle: "Use Cmd+Enter when the dictionary preview says the word can be added",
                    systemImage: "magnifyingglass"
                ))
            )
        }

        return results
    }

    private func buildCommandItems() -> [CommandPaletteItem] {
        let commandQuery = String(query.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        let commands = allCommands()
        guard !commandQuery.isEmpty else {
            let history = historyStore.load()
            let recentCommandIDs = Set(history.recentCommandIDs)
            let recentCommands = history.recentCommandIDs.compactMap { id in
                commands.first(where: { $0.id == id })
            }
            let remaining = commands.filter { !recentCommandIDs.contains($0.id) }
            let ordered = recentCommands + remaining
            return ordered.map(CommandPaletteItem.command)
        }

        let matches = commands.compactMap { command -> (CommandPaletteCommandItem, Int)? in
            let fields = [command.title] + command.keywords
            let score = fields.compactMap { FuzzyMatcher.score(query: commandQuery, candidate: $0) }.max()
            guard let score else { return nil }
            return (command, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }
        .map(\.0)

        if matches.isEmpty {
            return [
                .info(.init(
                    id: "no-command-results",
                    title: "No matching command",
                    subtitle: "Try >export, >batch add, or >sync",
                    systemImage: "command"
                ))
            ]
        }

        return matches.map(CommandPaletteItem.command)
    }

    private func buildCollectionItems() -> [CommandPaletteItem] {
        let trimmedQuery = rawTrimmedQuery
        let matches = wordListViewModel.collections.compactMap { collection -> (PersistedCollectionRecord, Int)? in
            let score = trimmedQuery.isEmpty
                ? 0
                : FuzzyMatcher.score(query: trimmedQuery, candidate: collection.name)
            if trimmedQuery.isEmpty {
                return (collection, 0)
            }
            guard let score else { return nil }
            return (collection, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.createdAt < rhs.0.createdAt
        }
        .map(\.0)

        if matches.isEmpty {
            return [
                .info(.init(
                    id: "no-collections",
                    title: "No matching collection",
                    subtitle: nil,
                    systemImage: "books.vertical"
                ))
            ]
        }

        return matches.map { collection in
            .collection(
                .init(
                    collectionID: collection.id,
                    title: collection.name,
                    subtitle: "\(wordListViewModel.exportableWordCount(for: collection.id)) ready"
                )
            )
        }
    }

    private func makeWordItem(from item: WordItem, isRecent: Bool) -> CommandPaletteWordItem {
        let trailingText: String?
        switch item.lookupState {
        case .pending:
            trailingText = "Pending"
        case .loading:
            trailingText = "Loading"
        case .loaded:
            trailingText = "Ready"
        case .failed:
            trailingText = "Failed"
        }

        return CommandPaletteWordItem(
            wordID: item.id,
            title: item.word,
            subtitle: item.phonetic.isEmpty ? item.sourceDescription : item.phonetic,
            trailingText: trailingText,
            isRecent: isRecent
        )
    }

    private func scheduleValidationIfNeeded() {
        validationTask?.cancel()
        validationTask = nil

        guard mode == .words else {
            lookupValidationState = .idle
            return
        }

        let trimmedQuery = rawTrimmedQuery
        let normalizedQuery = normalizedQuery
        guard !trimmedQuery.isEmpty else {
            lookupValidationState = .idle
            return
        }

        lookupValidationState = .checking(query: normalizedQuery)
        validationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let result = await self.wordListViewModel.validateWordCanBeAdded(trimmedQuery)
            guard !Task.isCancelled else { return }
            guard self.mode == .words, self.normalizedQuery == normalizedQuery else { return }
            self.lookupValidationState = .result(query: normalizedQuery, outcome: result)
            self.recomputeItems()
        }
    }

    private func performCommand(_ id: String) {
        switch id {
        case "batch-add":
            actions?.openBatchAdd()
            dismiss()
        case "export":
            actions?.openExport()
            dismiss()
        case "new-collection":
            actions?.openNewCollection()
            dismiss()
        case "collection-settings":
            actions?.openCollectionSettings()
            dismiss()
        case "switch-collection":
            mode = .collections
            query = ""
            lookupValidationState = .idle
            recomputeItems()
        case "sync-now":
            dismiss()
            Task { await self.actions?.syncNow() }
        case "sync-settings":
            actions?.openWindow(AppWindowIDs.syncSettings)
            dismiss()
        case "ai-settings":
            actions?.openWindow(AppWindowIDs.aiSettings)
            dismiss()
        case "help":
            actions?.openWindow(AppWindowIDs.help)
            dismiss()
        default:
            break
        }
    }

    private func allCommands() -> [CommandPaletteCommandItem] {
        [
            .init(id: "batch-add", title: "Batch Add", subtitle: "Add multiple words", systemImage: "text.badge.plus", keywords: ["batch", "import", "paste"]),
            .init(id: "export", title: "Export", subtitle: "Export current collection to Anki", systemImage: "square.and.arrow.up", keywords: ["anki", "export", "apkg"]),
            .init(id: "new-collection", title: "New Collection", subtitle: "Create a collection", systemImage: "plus.rectangle.on.folder", keywords: ["new", "create", "collection"]),
            .init(id: "collection-settings", title: "Collection Settings", subtitle: "Open current collection settings", systemImage: "book.closed", keywords: ["rename", "dictionary", "settings"]),
            .init(id: "switch-collection", title: "Switch Collection", subtitle: "Jump to another collection", systemImage: "books.vertical", keywords: ["switch", "collection", "jump"]),
            .init(id: "sync-now", title: "Sync Now", subtitle: "Start sync immediately", systemImage: "arrow.triangle.2.circlepath", keywords: ["sync", "webdav"]),
            .init(id: "sync-settings", title: "Sync Settings", subtitle: "Open sync settings", systemImage: "gearshape.2", keywords: ["sync", "settings", "webdav"]),
            .init(id: "ai-settings", title: "AI Settings", subtitle: "Open AI settings", systemImage: "sparkles", keywords: ["ai", "llm", "model"]),
            .init(id: "help", title: "Help", subtitle: "Open help", systemImage: "questionmark.circle", keywords: ["help", "guide"]),
        ]
    }

    private func defaultCommands(limit: Int) -> [CommandPaletteCommandItem] {
        Array(allCommands().prefix(limit))
    }
}
