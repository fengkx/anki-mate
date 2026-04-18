// LLMService — main public API for LLM features in the app.
// Manages the server lifecycle, model loading, and provides high-level generation methods.

import Foundation
import Combine
import AnkiMateRPC
import DictKit

@MainActor
public final class LLMService: ObservableObject {
    private static let selectedModelIdDefaultsKey = "ankimate.selectedModelId"
    private static let lastSuccessfulModelIdDefaultsKey = "ankimate.lastSuccessfullyLoadedModelId"
    private static let contextSizeEnvironmentKey = "DICTKIT_LLM_CONTEXT_SIZE"
    private static let gpuLayersEnvironmentKey = "DICTKIT_LLM_GPU_LAYERS"

    @Published public private(set) var serverState: ServerProcessManager.State = .stopped
    @Published public private(set) var loadedModelId: String?
    @Published public var selectedModelId: String {
        didSet {
            defaults.set(selectedModelId, forKey: Self.selectedModelIdDefaultsKey)
        }
    }

    public let registry: ModelRegistry
    public let downloadManager: ModelDownloadManager
    public let serverManager: ServerProcessManager

    private let rpcClient: RPCClient
    private let defaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()
    private var autoStartOnAvailableModel = false
    private var autoStartTask: Task<Void, Never>?

    public convenience init(defaults: UserDefaults = .standard) {
        let client = RPCClient()
        self.init(
            defaults: defaults,
            registry: ModelRegistry(),
            downloadManager: ModelDownloadManager(),
            serverManager: ServerProcessManager(rpcClient: client),
            rpcClient: client
        )
    }

    init(
        defaults: UserDefaults,
        registry: ModelRegistry,
        downloadManager: ModelDownloadManager,
        serverManager: ServerProcessManager,
        rpcClient: RPCClient
    ) {
        self.rpcClient = rpcClient
        self.defaults = defaults
        self.registry = registry
        self.downloadManager = downloadManager
        self.serverManager = serverManager
        self.selectedModelId = defaults.string(forKey: Self.selectedModelIdDefaultsKey) ?? ""

        // Observe server state changes
        serverManager.$state
            .assign(to: &$serverState)

        // Forward child changes so views that depend on derived download state refresh promptly.
        downloadManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        $selectedModelId
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleAutoActivationIfNeeded()
            }
            .store(in: &cancellables)

        downloadManager.$downloads
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleAutoActivationIfNeeded()
            }
            .store(in: &cancellables)
    }

    public func enableAutoStartOnAvailableModel() {
        guard !autoStartOnAvailableModel else { return }
        autoStartOnAvailableModel = true
        scheduleAutoActivationIfNeeded()
    }

    // MARK: - Server Lifecycle

    /// Start the server and load the selected model. Called lazily on first generation request.
    public func ensureReady() async throws {
        // Start server if not running
        if !serverState.isRunning {
            await serverManager.start()
        }

        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        // Load model if not already loaded
        if loadedModelId == nil || loadedModelId != selectedModelId {
            guard let model = registry.models.first(where: { $0.id == selectedModelId }) else {
                throw LLMServiceError.noModelSelected
            }

            guard downloadManager.isDownloaded(model) else {
                throw LLMServiceError.modelNotDownloaded
            }

            let modelPath = downloadManager.localPath(for: model).path
            let _: LoadModelResult = try await rpcClient.call(
                method: RPCMethod.loadModel,
                params: LoadModelParams(
                    modelPath: modelPath,
                    contextSize: Self.contextSizeOverride(defaultValue: model.contextSize),
                    gpuLayers: Self.gpuLayersOverride()
                ),
                port: port
            )

            loadedModelId = model.id
            defaults.set(model.id, forKey: Self.lastSuccessfulModelIdDefaultsKey)
        }
    }

    /// Stop the server.
    public func stopServer() async {
        await serverManager.stop()
        loadedModelId = nil
    }

    /// Start the server without triggering model load.
    public func startServer() async {
        await serverManager.start()
    }

    public func autoActivateInferenceServerIfPossible() async {
        guard autoStartOnAvailableModel else { return }

        let downloadedModels = registry.models.filter { downloadManager.isDownloaded($0) }
        guard !downloadedModels.isEmpty else { return }

        if let resolvedModelId = Self.resolveAutoSelectedModelId(
            lastSuccessfullyLoadedModelId: defaults.string(forKey: Self.lastSuccessfulModelIdDefaultsKey),
            currentSelectedModelId: selectedModelId,
            registryModels: registry.models,
            downloadedModelIDs: Set(downloadedModels.map(\.id))
        ), resolvedModelId != selectedModelId {
            selectedModelId = resolvedModelId
        }

        guard hasModel else { return }
        guard serverState != .starting, !serverState.isRunning else { return }

        do {
            try await ensureReady()
        } catch {
            // Best effort: keep the auto-start path non-fatal and leave the UI state intact.
        }
    }

    // MARK: - High-Level Generation

    /// Generate example sentences for a word.
    public func generateExampleSentences(
        word: String,
        definition: String,
        partOfSpeech: String
    ) async throws -> [String] {
        try await generateExampleSentences(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ]
        )
    }

    public func generateExampleSentences(
        word: String,
        senses: [LLMSensePromptInput]
    ) async throws -> [String] {
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.exampleSentences(
            word: word,
            senses: senses
        )
        let sentenceCount = LLMPrompt.exampleSentenceCount(for: senses)

        let result: GenerateResult = try await rpcClient.call(
            method: RPCMethod.generate,
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: max(300, sentenceCount * 96),
                temperature: 0.7
            ),
            port: port
        )

        // Parse numbered sentences
        return parseSentences(result.text)
    }

    public func generateExampleSentenceArtifacts(
        word: String,
        definition: String,
        partOfSpeech: String
    ) async throws -> [LLMExampleSentence] {
        try await generateExampleSentenceArtifacts(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ]
        )
    }

    public func generateExampleSentenceArtifacts(
        word: String,
        senses: [LLMSensePromptInput]
    ) async throws -> [LLMExampleSentence] {
        let prompt = LLMPrompt.exampleSentenceArtifacts(
            word: word,
            senses: senses
        )
        let desiredCount = LLMPrompt.exampleSentenceCount(for: senses)

        let response: ExampleSentenceEnvelope = try await generateStructuredOutput(
            type: ExampleSentenceEnvelope.self,
            prompt: prompt,
            maxTokens: max(420, desiredCount * 150),
            temperature: 0.45,
            responseFormat: LLMResponseFormat(kind: .json)
        )

        return normalizeExampleSentences(
            response.examples,
            senseCount: max(1, senses.count),
            desiredCount: desiredCount
        )
    }

    public func generateExampleSentencesStreaming(
        word: String,
        definition: String,
        partOfSpeech: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> [String] {
        try await generateExampleSentencesStreaming(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            onDelta: onDelta
        )
    }

    public func generateExampleSentencesStreaming(
        word: String,
        senses: [LLMSensePromptInput],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> [String] {
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.exampleSentences(
            word: word,
            senses: senses
        )
        let sentenceCount = LLMPrompt.exampleSentenceCount(for: senses)

        let result = try await rpcClient.streamGenerate(
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: max(360, sentenceCount * 112),
                temperature: 0.7
            ),
            port: port,
            onDelta: onDelta
        )
        return parseSentences(result.text)
    }

    /// Generate an optimized definition.
    public func optimizeDefinition(
        word: String,
        rawDefinition: String
    ) async throws -> String {
        try await optimizeDefinition(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "general",
                    definition: rawDefinition
                )
            ]
        )
    }

    public func optimizeDefinition(
        word: String,
        senses: [LLMSensePromptInput]
    ) async throws -> String {
        let hints = try await generateUsageHints(
            word: word,
            senses: senses
        )
        return Self.renderUsageHints(hints)
    }

    public func optimizeDefinitionStreaming(
        word: String,
        rawDefinition: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await optimizeDefinitionStreaming(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "general",
                    definition: rawDefinition
                )
            ],
            onDelta: onDelta
        )
    }

    public func optimizeDefinitionStreaming(
        word: String,
        senses: [LLMSensePromptInput],
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.legacyOptimizeDefinitionText(
            word: word,
            senses: senses
        )
        let hintCount = LLMPrompt.usageHintCount(for: senses)

        let result = try await rpcClient.streamGenerate(
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: max(260, hintCount * 104),
                temperature: 0.5
            ),
            port: port,
            onDelta: onDelta
        )
        return normalizeLegacyUsageHints(result.text)
    }

    public func generateUsageHints(
        word: String,
        definition: String,
        partOfSpeech: String
    ) async throws -> [LLMUsageHint] {
        try await generateUsageHints(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ]
        )
    }

    public func generateUsageHints(
        word: String,
        senses: [LLMSensePromptInput]
    ) async throws -> [LLMUsageHint] {
        let prompt = LLMPrompt.usageHints(
            word: word,
            senses: senses
        )
        let desiredCount = LLMPrompt.usageHintCount(for: senses)

        let response: UsageHintEnvelope = try await generateStructuredOutput(
            type: UsageHintEnvelope.self,
            prompt: prompt,
            maxTokens: max(320, desiredCount * 120),
            temperature: 0.35,
            responseFormat: LLMResponseFormat(kind: .json)
        )

        return Self.normalizeUsageHints(
            response.usageHints,
            senseCount: max(1, senses.count),
            desiredCount: desiredCount
        )
    }

    public func generateRecallCardDrafts(
        word: String,
        definition: String,
        partOfSpeech: String,
        modes: [LLMRecallCardMode] = LLMRecallCardMode.allCases,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMRecallCardDraft] {
        try await generateRecallCardDrafts(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            modes: modes,
            anchor: anchor
        )
    }

    public func generateRecallCardDrafts(
        word: String,
        senses: [LLMSensePromptInput],
        modes: [LLMRecallCardMode] = LLMRecallCardMode.allCases,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMRecallCardDraft] {
        let requestedModes = modes.isEmpty ? [.fullSpelling] : modes
        var drafts: [LLMRecallCardDraft] = []

        for requestedMode in requestedModes {
            drafts.append(
                try await generateRecallCardDraft(
                    word: word,
                    senses: senses,
                    mode: requestedMode,
                    anchor: anchor
                )
            )
        }

        return drafts
    }

    public func generatePhoneticIPA(
        word: String,
        dialect: String? = nil,
        pronunciationGuide: String? = nil,
        senses: [LLMSensePromptInput]
    ) async throws -> String {
        let prompt = LLMPrompt.phoneticIPA(
            word: word,
            dialect: dialect,
            pronunciationGuide: pronunciationGuide,
            senses: senses
        )

        let response: GeneratedIPAPayload = try await generateStructuredOutput(
            type: GeneratedIPAPayload.self,
            prompt: prompt,
            maxTokens: 80,
            temperature: 0.2
        )

        guard let normalized = Self.normalizeGeneratedIPA(response.ipa) else {
            throw LLMServiceError.invalidStructuredOutput("Expected one valid IPA string")
        }

        return normalized
    }

    public func generatePronunciationEnhancement(
        word: String,
        dialect: String? = nil,
        pronunciationGuide: String? = nil,
        existingIPA: String? = nil,
        senses: [LLMSensePromptInput]
    ) async throws -> LLMPronunciationEnhancement {
        do {
            return try await generatePronunciationEnhancement(
                word: word,
                dialect: dialect,
                pronunciationGuide: pronunciationGuide,
                existingIPA: existingIPA,
                senses: senses,
                strictSpellingRetry: false
            )
        } catch LLMServiceError.invalidStructuredOutput {
            return try await generatePronunciationEnhancement(
                word: word,
                dialect: dialect,
                pronunciationGuide: pronunciationGuide,
                existingIPA: existingIPA,
                senses: senses,
                strictSpellingRetry: true
            )
        }
    }

    private func generatePronunciationEnhancement(
        word: String,
        dialect: String?,
        pronunciationGuide: String?,
        existingIPA: String?,
        senses: [LLMSensePromptInput],
        strictSpellingRetry: Bool
    ) async throws -> LLMPronunciationEnhancement {
        let prompt = LLMPrompt.pronunciationEnhancement(
            word: word,
            dialect: dialect,
            pronunciationGuide: pronunciationGuide,
            existingIPA: existingIPA,
            senses: senses,
            strictSpellingRetry: strictSpellingRetry
        )

        let response: GeneratedPronunciationEnhancementPayload = try await generateStructuredOutput(
            type: GeneratedPronunciationEnhancementPayload.self,
            prompt: prompt,
            maxTokens: 120,
            temperature: strictSpellingRetry ? 0.1 : 0.2
        )

        guard let normalizedStress = Self.normalizeStressSyllables(response.stressSyllables, preservingSpellingOf: word) else {
            throw LLMServiceError.invalidStructuredOutput("Expected one valid stress syllables string")
        }

        let normalizedIPA = Self.normalizeGeneratedIPA(response.ipa)

        return LLMPronunciationEnhancement(
            ipa: normalizedIPA,
            stressSyllables: normalizedStress
        )
    }

    public func generateRecallCardDraft(
        word: String,
        definition: String,
        partOfSpeech: String,
        mode: LLMRecallCardMode,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMRecallCardDraft {
        try await generateRecallCardDraft(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            mode: mode,
            anchor: anchor
        )
    }

    public func generateRecallCardDraft(
        word: String,
        senses: [LLMSensePromptInput],
        mode: LLMRecallCardMode,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMRecallCardDraft {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let scaffold = Self.recallPromptScaffold(
            word: normalizedWord,
            senses: senses,
            mode: mode
        )
        let prompt = LLMPrompt.recallCardDraft(
            word: normalizedWord,
            senses: senses,
            requestedMode: mode,
            anchor: anchor,
            scaffold: scaffold
        )

        do {
            let response: RecallCardDraftEnvelope = try await generateStructuredOutput(
                type: RecallCardDraftEnvelope.self,
                prompt: prompt,
                maxTokens: 320,
                temperature: 0.3,
                responseFormat: LLMResponseFormat(kind: .json)
            )

            if let payload = response.primaryDraft ?? response.drafts.first,
               let draft = Self.normalizeRecallCardDraft(
                   payload,
                   expectedMode: mode,
                   target: normalizedWord
               ) {
                return draft
            }
        } catch {
            if let fallback = Self.ruleBasedRecallCardDraft(
                word: normalizedWord,
                senses: senses,
                mode: mode,
                anchor: anchor
            ) {
                return fallback
            }
            throw error
        }

        if let fallback = Self.ruleBasedRecallCardDraft(
            word: normalizedWord,
            senses: senses,
            mode: mode,
            anchor: anchor
        ) {
            return fallback
        }

        throw LLMServiceError.invalidStructuredOutput(
            "Expected one valid recall draft for mode \(mode.rawValue)"
        )
    }

    public func generateLearningAids(
        word: String,
        definition: String,
        partOfSpeech: String,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMLearningAids {
        try await generateLearningAids(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            anchor: anchor
        )
    }

    public func generateLearningAids(
        word: String,
        senses: [LLMSensePromptInput],
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMLearningAids {
        let prompt = LLMPrompt.learningAids(
            word: word,
            senses: senses,
            anchor: anchor
        )

        let response: LearningAidsEnvelope = try await generateStructuredOutput(
            type: LearningAidsEnvelope.self,
            prompt: prompt,
            maxTokens: 560,
            temperature: 0.4,
            responseFormat: LLMResponseFormat(kind: .json)
        )

        return Self.normalizeLearningAids(response)
    }

    public func generatePitfalls(
        word: String,
        definition: String,
        partOfSpeech: String,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMPitfall] {
        try await generatePitfalls(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            anchor: anchor
        )
    }

    public func generatePitfalls(
        word: String,
        senses: [LLMSensePromptInput],
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMPitfall] {
        let aids = try await generateLearningAids(
            word: word,
            senses: senses,
            anchor: anchor
        )
        return aids.pitfalls
    }

    public func generateMnemonics(
        word: String,
        definition: String,
        partOfSpeech: String,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMMnemonic] {
        try await generateMnemonics(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            anchor: anchor
        )
    }

    public func generateMnemonics(
        word: String,
        senses: [LLMSensePromptInput],
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMMnemonic] {
        let aids = try await generateLearningAids(
            word: word,
            senses: senses,
            anchor: anchor
        )
        return aids.mnemonics
    }

    public func generateCollocations(
        word: String,
        definition: String,
        partOfSpeech: String,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMCollocation] {
        try await generateCollocations(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            anchor: anchor
        )
    }

    public func generateCollocations(
        word: String,
        senses: [LLMSensePromptInput],
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> [LLMCollocation] {
        let aids = try await generateLearningAids(
            word: word,
            senses: senses,
            anchor: anchor
        )
        return aids.collocations
    }

    // MARK: - Helpers

    private func parseSentences(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { Self.normalizeGeneratedLine(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func normalizeExampleSentences(
        _ examples: [LLMExampleSentence],
        senseCount: Int,
        desiredCount: Int
    ) -> [LLMExampleSentence] {
        examples.compactMap { example in
            let english = Self.normalizeGeneratedLine(
                example.english,
                stripFieldLabels: true
            )
            let translation = Self.normalizeGeneratedLine(
                example.translation,
                stripFieldLabels: true
            )
            guard !english.isEmpty, !translation.isEmpty else { return nil }

            let normalizedSenseIndex: Int?
            if let senseIndex = example.senseIndex, (1...senseCount).contains(senseIndex) {
                normalizedSenseIndex = senseIndex
            } else if senseCount == 1 {
                normalizedSenseIndex = 1
            } else {
                normalizedSenseIndex = nil
            }

            return LLMExampleSentence(
                english: english,
                translation: translation,
                senseIndex: normalizedSenseIndex
            )
        }
        .prefix(desiredCount)
        .map { $0 }
    }

    private func normalizeLegacyUsageHints(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map {
                Self.normalizeGeneratedLine(
                    String($0),
                    convertBilingualLabels: true,
                    stripFieldLabels: true
                )
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func renderUsageHints(_ hints: [LLMUsageHint]) -> String {
        hints.map { hint in
            let translation = hint.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            if translation.isEmpty {
                return hint.text
            }
            return "\(hint.text) — \(translation)"
        }
        .joined(separator: "\n")
    }

    static func normalizeUsageHints(
        _ hints: [UsageHintPayload],
        senseCount: Int,
        desiredCount: Int
    ) -> [LLMUsageHint] {
        hints.compactMap { hint in
            let text = normalizeGeneratedLine(
                hint.text,
                stripFieldLabels: true
            )
            let translation = normalizeGeneratedLine(
                hint.translation,
                stripFieldLabels: true
            )
            guard !text.isEmpty, !translation.isEmpty else { return nil }

            let normalizedSenseIndex: Int?
            if let senseIndex = hint.senseIndex, (1...senseCount).contains(senseIndex) {
                normalizedSenseIndex = senseIndex
            } else if senseCount == 1 {
                normalizedSenseIndex = 1
            } else {
                normalizedSenseIndex = nil
            }

            return LLMUsageHint(
                text: text,
                translation: translation,
                kind: normalizedUsageHintKind(hint.kind),
                senseIndex: normalizedSenseIndex
            )
        }
        .prefix(desiredCount)
        .map { $0 }
    }

    private static func normalizeGeneratedLine(
        _ text: String,
        convertBilingualLabels: Bool = false,
        stripFieldLabels: Bool = false
    ) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        while let stripped = stripListMarker(from: normalized) {
            normalized = stripped
        }

        if convertBilingualLabels {
            normalized = rewriteBilingualLabels(in: normalized) ?? normalized
        }

        if stripFieldLabels {
            while let stripped = stripStructuredFieldLabel(from: normalized) {
                normalized = stripped
            }
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripListMarker(from text: String) -> String? {
        guard let range = text.range(
            of: #"^(?:[-*•]\s+|\d+\s*[\.\)\:\-–—]\s+)"#,
            options: .regularExpression
        ) else {
            return nil
        }

        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripStructuredFieldLabel(from text: String) -> String? {
        guard let range = text.range(
            of: #"^(?:(?:English|Chinese|Translation|Meaning|Text|Summary|Details|Clue|Phrase|Hint|Front|Back|Pitfall|Usage|Collocation|Mnemonic|EN|ZH)\s*:\s*)"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rewriteBilingualLabels(in text: String) -> String? {
        let pattern = #"^(?:[A-Za-z][A-Za-z /-]*\s+)?EN:\s*(.+?)\s*\|\s*ZH:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = regex.firstMatch(in: text, range: nsRange),
              let enRange = Range(result.range(at: 1), in: text),
              let zhRange = Range(result.range(at: 2), in: text) else {
            return nil
        }

        return "\(text[enRange]) — \(text[zhRange])"
    }

    private static func normalizedUsageHintKind(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case "sense_distinction", "sensedistinction":
            return "sense_distinction"
        case "usage_tendency", "usagetendency":
            return "usage_tendency"
        case "semantic_contrast", "semanticcontrast":
            return "semantic_contrast"
        case "register_or_context", "registerorcontext":
            return "register_or_context"
        default:
            return normalized.nilIfEmpty
        }
    }

    private func generateStructuredOutput<T: Decodable>(
        type: T.Type,
        prompt: (system: String, user: String),
        maxTokens: Int,
        temperature: Float,
        responseFormat: LLMResponseFormat? = nil
    ) async throws -> T {
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let result: GenerateResult = try await rpcClient.call(
            method: RPCMethod.generate,
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                responseFormat: responseFormat,
                maxTokens: maxTokens,
                temperature: temperature
            ),
            port: port
        )

        return try Self.decodeStructuredOutput(type, from: result.text)
    }

    /// Whether the service is ready for generation (server running, model loaded).
    public var isReady: Bool {
        serverState.isRunning && loadedModelId != nil
    }

    /// Whether a model is selected and downloaded.
    public var hasModel: Bool {
        guard let model = registry.models.first(where: { $0.id == selectedModelId }) else {
            return false
        }
        return downloadManager.isDownloaded(model)
    }

    static func resolveAutoSelectedModelId(
        lastSuccessfullyLoadedModelId: String?,
        currentSelectedModelId: String,
        registryModels: [ModelInfo],
        downloadedModelIDs: Set<String>
    ) -> String? {
        guard !downloadedModelIDs.isEmpty else { return nil }
        if let lastSuccessfullyLoadedModelId,
           downloadedModelIDs.contains(lastSuccessfullyLoadedModelId) {
            return lastSuccessfullyLoadedModelId
        }
        if downloadedModelIDs.contains(currentSelectedModelId) {
            return currentSelectedModelId
        }
        return registryModels.first(where: { downloadedModelIDs.contains($0.id) })?.id
    }

    private func scheduleAutoActivationIfNeeded() {
        guard autoStartOnAvailableModel else { return }
        autoStartTask?.cancel()
        autoStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.autoActivateInferenceServerIfPossible()
        }
    }

    static func gpuLayersOverride(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
        guard let rawValue = environment[gpuLayersEnvironmentKey],
              let parsed = Int(rawValue) else {
            return 99
        }

        return max(parsed, 0)
    }

    static func contextSizeOverride(
        defaultValue: Int,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let rawValue = environment[contextSizeEnvironmentKey],
              let parsed = Int(rawValue) else {
            return defaultValue
        }

        return max(parsed, 512)
    }
}

struct RecallCardDraftEnvelope: Decodable {
    let primaryDraft: RecallCardDraftPayload?
    let drafts: [RecallCardDraftPayload]

    private enum CodingKeys: String, CodingKey {
        case draft
        case drafts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.primaryDraft = try container.decodeIfPresent(RecallCardDraftPayload.self, forKey: .draft)
        self.drafts = try container.decodeIfPresent([RecallCardDraftPayload].self, forKey: .drafts) ?? []
    }
}

private struct GeneratedIPAPayload: Decodable {
    let ipa: String
}

private struct GeneratedPronunciationEnhancementPayload: Decodable {
    let ipa: String?
    let stressSyllables: String
}

public struct LLMPronunciationEnhancement: Equatable, Sendable {
    public let ipa: String?
    public let stressSyllables: String

    public init(ipa: String?, stressSyllables: String) {
        self.ipa = ipa
        self.stressSyllables = stressSyllables
    }
}

struct ExampleSentenceEnvelope: Decodable {
    let examples: [LLMExampleSentence]

    private enum CodingKeys: String, CodingKey {
        case examples
        case sentences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.examples =
            try container.decodeIfPresent([LLMExampleSentence].self, forKey: .examples)
            ?? container.decodeIfPresent([LLMExampleSentence].self, forKey: .sentences)
            ?? []
    }
}

struct RecallCardDraftPayload: Decodable {
    let mode: String
    let front: String
    let back: String
    let hint: String?
    let anchor: LLMAnchorSnapshot?

    private enum CodingKeys: String, CodingKey {
        case mode
        case type
        case front
        case question
        case back
        case answer
        case hint
        case anchor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode =
            try container.decodeIfPresent(String.self, forKey: .mode)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? ""
        self.front =
            try container.decodeIfPresent(String.self, forKey: .front)
            ?? container.decodeIfPresent(String.self, forKey: .question)
            ?? ""
        self.back =
            try container.decodeIfPresent(String.self, forKey: .back)
            ?? container.decodeIfPresent(String.self, forKey: .answer)
            ?? ""
        self.hint = try container.decodeIfPresent(String.self, forKey: .hint)
        self.anchor = try container.decodeIfPresent(LLMAnchorSnapshot.self, forKey: .anchor)
    }
}

struct UsageHintEnvelope: Decodable {
    let usageHints: [UsageHintPayload]

    private enum CodingKeys: String, CodingKey {
        case usageHints
        case usage
        case hints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usageHints =
            try container.decodeIfPresent([UsageHintPayload].self, forKey: .usageHints)
            ?? container.decodeIfPresent([UsageHintPayload].self, forKey: .usage)
            ?? container.decodeIfPresent([UsageHintPayload].self, forKey: .hints)
            ?? []
    }
}

struct UsageHintPayload: Decodable {
    let text: String
    let translation: String
    let kind: String?
    let senseIndex: Int?

    private enum CodingKeys: String, CodingKey {
        case text
        case summary
        case english
        case translation
        case chinese
        case zh
        case details
        case kind
        case category
        case senseIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text =
            try container.decodeIfPresent(String.self, forKey: .text)
            ?? container.decodeIfPresent(String.self, forKey: .summary)
            ?? container.decodeIfPresent(String.self, forKey: .english)
            ?? ""
        self.translation =
            try container.decodeIfPresent(String.self, forKey: .translation)
            ?? container.decodeIfPresent(String.self, forKey: .chinese)
            ?? container.decodeIfPresent(String.self, forKey: .zh)
            ?? container.decodeIfPresent(String.self, forKey: .details)
            ?? ""
        self.kind =
            try container.decodeIfPresent(String.self, forKey: .kind)
            ?? container.decodeIfPresent(String.self, forKey: .category)
        self.senseIndex = try container.decodeIfPresent(Int.self, forKey: .senseIndex)
    }
}

struct LearningAidsEnvelope: Decodable {
    let pitfalls: [PitfallPayload]
    let mnemonics: [MnemonicPayload]
    let collocations: [CollocationPayload]

    init(
        pitfalls: [PitfallPayload] = [],
        mnemonics: [MnemonicPayload] = [],
        collocations: [CollocationPayload] = []
    ) {
        self.pitfalls = pitfalls
        self.mnemonics = mnemonics
        self.collocations = collocations
    }

    private enum CodingKeys: String, CodingKey {
        case pitfalls
        case mnemonics
        case collocations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pitfalls = try container.decodeIfPresent([PitfallPayload].self, forKey: .pitfalls) ?? []
        self.mnemonics = try container.decodeIfPresent([MnemonicPayload].self, forKey: .mnemonics) ?? []
        self.collocations = try container.decodeIfPresent([CollocationPayload].self, forKey: .collocations) ?? []
    }
}

struct PitfallPayload: Decodable {
    let summary: String
    let details: String?
    let anchor: LLMAnchorSnapshot?
}

struct MnemonicPayload: Decodable {
    let clue: String
    let anchor: LLMAnchorSnapshot?
}

struct CollocationPayload: Decodable {
    let phrase: String
    let gloss: String?
    let anchor: LLMAnchorSnapshot?
}

extension LLMService {
    static func decodeStructuredOutput<T: Decodable>(
        _ type: T.Type,
        from text: String
    ) throws -> T {
        let decoder = JSONDecoder()
        var attemptedPayloads: [String] = []

        for candidate in structuredOutputCandidates(from: text) {
            guard !attemptedPayloads.contains(candidate) else { continue }
            attemptedPayloads.append(candidate)

            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }

        throw LLMServiceError.invalidStructuredOutput(
            "Expected JSON object for structured output"
        )
    }

    static func normalizeRecallCardDrafts(
        _ payloads: [RecallCardDraftPayload],
        requestedModes: [LLMRecallCardMode],
        target: String
    ) -> [LLMRecallCardDraft] {
        let requestedModeSet = Set(requestedModes)
        var draftsByMode: [LLMRecallCardMode: LLMRecallCardDraft] = [:]

        for payload in payloads {
            guard let mode = normalizedRecallCardMode(from: payload.mode),
                  requestedModeSet.contains(mode),
                  draftsByMode[mode] == nil,
                  let draft = normalizeRecallCardDraft(
                      payload,
                      expectedMode: mode,
                      target: target
                  ) else {
                continue
            }
            draftsByMode[mode] = draft
        }

        return requestedModes.compactMap { draftsByMode[$0] }
    }

    static func normalizeLearningAids(_ payload: LearningAidsEnvelope) -> LLMLearningAids {
        LLMLearningAids(
            pitfalls: payload.pitfalls.compactMap(normalizePitfall),
            mnemonics: payload.mnemonics.compactMap(normalizeMnemonic),
            collocations: payload.collocations.compactMap(normalizeCollocation)
        )
    }

    private static func structuredOutputCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates = [trimmed]
        candidates.append(contentsOf: fencedCodeBlockContents(in: trimmed))

        if let object = firstBalancedJSONBlock(in: trimmed, opening: "{", closing: "}") {
            candidates.append(object)
        }
        if let array = firstBalancedJSONBlock(in: trimmed, opening: "[", closing: "]") {
            candidates.append(array)
        }

        for block in fencedCodeBlockContents(in: trimmed) {
            if let object = firstBalancedJSONBlock(in: block, opening: "{", closing: "}") {
                candidates.append(object)
            }
            if let array = firstBalancedJSONBlock(in: block, opening: "[", closing: "]") {
                candidates.append(array)
            }
        }

        return candidates
    }

    private static func fencedCodeBlockContents(in text: String) -> [String] {
        let pattern = #"```(?:json)?\s*([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func firstBalancedJSONBlock(
        in text: String,
        opening: Character,
        closing: Character
    ) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaping = false

        for index in text.indices {
            let character = text[index]

            if isInsideString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
                continue
            }

            if character == opening {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
                continue
            }

            guard character == closing, depth > 0 else { continue }
            depth -= 1

            if depth == 0, let startIndex {
                let endIndex = text.index(after: index)
                return String(text[startIndex..<endIndex])
            }
        }

        return nil
    }

    private static func normalizedRecallCardMode(from rawValue: String) -> LLMRecallCardMode? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalized {
        case LLMRecallCardMode.fullSpelling.rawValue, "fullspelling":
            return .fullSpelling
        case LLMRecallCardMode.targetedLetterCloze.rawValue, "targetedlettercloze":
            return .targetedLetterCloze
        case LLMRecallCardMode.phraseRecall.rawValue, "phraserecall":
            return .phraseRecall
        default:
            return nil
        }
    }

    private static func normalizeRecallCardDraft(
        _ payload: RecallCardDraftPayload,
        expectedMode: LLMRecallCardMode,
        target: String
    ) -> LLMRecallCardDraft? {
        guard let mode = normalizedRecallCardMode(from: payload.mode),
              mode == expectedMode else {
            return nil
        }

        let front = normalizeGeneratedLine(
            payload.front,
            stripFieldLabels: true
        )
        let back = normalizeGeneratedLine(
            payload.back,
            stripFieldLabels: true
        )
        guard !front.isEmpty, !back.isEmpty else { return nil }
        guard back == target.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        if mode == .targetedLetterCloze,
           !front.contains("_"),
           !(payload.hint?.contains("_") ?? false) {
            return nil
        }

        let hint = payload.hint.map {
            normalizeGeneratedLine(
                $0,
                stripFieldLabels: true
            )
        }?.nilIfEmpty
        let anchor = normalizeAnchor(payload.anchor)
        return LLMRecallCardDraft(
            mode: mode,
            front: front,
            back: back,
            hint: hint,
            anchor: anchor
        )
    }

    static func ruleBasedRecallCardDraft(
        word: String,
        senses: [LLMSensePromptInput],
        mode: LLMRecallCardMode,
        anchor: LLMAnchorSnapshot?
    ) -> LLMRecallCardDraft? {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWord.isEmpty else { return nil }

        let scaffold = recallPromptScaffold(
            word: normalizedWord,
            senses: senses,
            mode: mode
        )
        let cue = scaffold.learnerCue ?? ""
        let hint = scaffold.hint
        let resolvedAnchor = normalizeAnchor(anchor)

        switch mode {
        case .fullSpelling:
            let front = cue.nilIfEmpty.map { "\($0) · spell the exact word" } ?? "Spell the exact target word."
            return LLMRecallCardDraft(
                mode: .fullSpelling,
                front: front,
                back: normalizedWord,
                hint: hint,
                anchor: resolvedAnchor
            )

        case .targetedLetterCloze:
            guard let maskedWord = ruleBasedMaskedSurface(for: normalizedWord) else { return nil }
            let front = cue.nilIfEmpty.map { "\($0) · \(maskedWord)" } ?? maskedWord
            return LLMRecallCardDraft(
                mode: .targetedLetterCloze,
                front: front,
                back: normalizedWord,
                hint: hint,
                anchor: resolvedAnchor
            )

        case .phraseRecall:
            let front = cue.nilIfEmpty.map { "\($0) · recall the exact phrase" } ?? "Recall the exact phrase."
            return LLMRecallCardDraft(
                mode: .phraseRecall,
                front: front,
                back: normalizedWord,
                hint: hint,
                anchor: resolvedAnchor
            )
        }
    }

    static func normalizeGeneratedIPA(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Pronunciation(dialect: nil, ipa: trimmed, respelling: nil).ttsIPANotation
    }

    static func normalizeStressSyllables(_ rawValue: String?, preservingSpellingOf word: String? = nil) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }

        let rawCandidates = trimmed.components(
            separatedBy: CharacterSet(charactersIn: ",/;\n")
        )

        for rawCandidate in rawCandidates {
            let candidate = rawCandidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespaces)
                .joined()
            guard !candidate.isEmpty else { continue }
            if let normalized = normalizeStressSyllableCandidate(candidate, preservingSpellingOf: word) {
                return normalized
            }
        }

        return nil
    }

    private static func normalizeStressSyllableCandidate(_ candidate: String, preservingSpellingOf word: String?) -> String? {
        let syllables = candidate
            .split(separator: "-", omittingEmptySubsequences: true)
            .map(String.init)
        guard !syllables.isEmpty else { return nil }
        guard syllables.allSatisfy({
            $0.range(of: #"^[A-Za-z]+$"#, options: .regularExpression) != nil
        }) else {
            return nil
        }

        if syllables.count == 1 {
            return syllables[0].lowercased()
        }

        let stressedIndexes = syllables.enumerated().compactMap { index, syllable in
            syllable.rangeOfCharacter(from: .uppercaseLetters) == nil ? nil : index
        }
        guard stressedIndexes.count == 1, let stressedIndex = stressedIndexes.first else {
            return nil
        }

        let normalized = syllables.enumerated().map { index, syllable in
            index == stressedIndex ? syllable.uppercased() : syllable.lowercased()
        }
        let normalizedJoined = normalized.joined(separator: "-")

        if let word {
            let compactWord = word.lowercased().filter(\.isLetter)
            let compactCandidate = normalizedJoined.lowercased().filter(\.isLetter)
            guard !compactWord.isEmpty, compactWord == compactCandidate else { return nil }
        }

        return normalizedJoined
    }

    static func recallPromptScaffold(
        word: String,
        senses: [LLMSensePromptInput],
        mode: LLMRecallCardMode
    ) -> RecallPromptScaffold {
        RecallPromptScaffold(
            learnerCue: fallbackRecallCue(from: senses).nilIfEmpty,
            hint: fallbackRecallHint(from: senses),
            requiredMaskedSurface: mode == .targetedLetterCloze
                ? ruleBasedMaskedSurface(for: word)
                : nil
        )
    }

    private static func fallbackRecallCue(from senses: [LLMSensePromptInput]) -> String {
        guard let primary = senses.first else { return "" }
        let preferred = primary.semanticHint?.nilIfEmpty ?? primary.definition
        let compact = preferred
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return primary.partOfSpeech }
        return compact.count > 44 ? String(compact.prefix(44)).trimmingCharacters(in: .whitespacesAndNewlines) : compact
    }

    private static func fallbackRecallHint(from senses: [LLMSensePromptInput]) -> String? {
        guard let primary = senses.first else { return nil }
        let parts = [
            primary.partOfSpeech.trimmingCharacters(in: .whitespacesAndNewlines),
            primary.semanticHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ]
        .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " · ")
        return joined.count > 36 ? String(joined.prefix(36)).trimmingCharacters(in: .whitespacesAndNewlines) : joined
    }

    private static func ruleBasedMaskedSurface(for word: String) -> String? {
        let characters = Array(word)
        guard characters.count >= 4 else { return nil }

        let lowercased = characters.map { Character(String($0).lowercased()) }

        if let range = preferredMaskRange(in: lowercased) {
            return applyingMask(range: range, to: characters)
        }

        let fallbackStart = max(1, min(characters.count - 3, (characters.count / 2) - 1))
        let fallbackLength = min(2, characters.count - fallbackStart - 1)
        guard fallbackLength >= 2 else { return nil }
        return applyingMask(range: fallbackStart..<(fallbackStart + fallbackLength), to: characters)
    }

    private static func preferredMaskRange(in characters: [Character]) -> Range<Int>? {
        let word = String(characters)

        if let repeatedRange = firstRepeatedLetterRange(in: characters) {
            return repeatedRange
        }

        let vowelClusters = ["ie", "ei", "ea", "ee", "oo", "ou", "oa", "ai", "au", "oi", "ue", "ui", "io"]
        for cluster in vowelClusters {
            if let range = internalSubstringRange(of: cluster, in: word) {
                return range
            }
        }

        let suffixFragments = ["ion", "ian", "ial", "ual", "ous", "ive", "ize", "ise", "ate", "ent", "ant"]
        for fragment in suffixFragments {
            if let range = internalSubstringRange(of: fragment, in: word) {
                return range
            }
        }

        return nil
    }

    private static func firstRepeatedLetterRange(in characters: [Character]) -> Range<Int>? {
        guard characters.count >= 4 else { return nil }

        for index in 1..<(characters.count - 1) {
            guard characters[index] == characters[index - 1] else { continue }
            let start = index - 1
            let end = index + 1
            guard start > 0, end < characters.count else { continue }
            return start..<end
        }

        return nil
    }

    private static func internalSubstringRange(of substring: String, in word: String) -> Range<Int>? {
        guard let range = word.range(of: substring, options: [.caseInsensitive]) else { return nil }
        let lowerBound = word.distance(from: word.startIndex, to: range.lowerBound)
        let upperBound = word.distance(from: word.startIndex, to: range.upperBound)
        guard lowerBound > 0, upperBound < word.count else { return nil }
        return lowerBound..<upperBound
    }

    private static func applyingMask(range: Range<Int>, to characters: [Character]) -> String {
        characters.enumerated().map { index, character in
            range.contains(index) ? "_" : String(character)
        }
        .joined()
    }

    private static func normalizePitfall(_ payload: PitfallPayload) -> LLMPitfall? {
        let summary = normalizeGeneratedLine(
            payload.summary,
            stripFieldLabels: true
        )
        guard !summary.isEmpty else { return nil }
        return LLMPitfall(
            summary: summary,
            details: payload.details.map {
                normalizeGeneratedLine(
                    $0,
                    stripFieldLabels: true
                )
            }?.nilIfEmpty,
            anchor: normalizeAnchor(payload.anchor)
        )
    }

    private static func normalizeMnemonic(_ payload: MnemonicPayload) -> LLMMnemonic? {
        let clue = normalizeGeneratedLine(
            payload.clue,
            stripFieldLabels: true
        )
        guard !clue.isEmpty else { return nil }
        return LLMMnemonic(
            clue: clue,
            anchor: normalizeAnchor(payload.anchor)
        )
    }

    private static func normalizeCollocation(_ payload: CollocationPayload) -> LLMCollocation? {
        let phrase = normalizeGeneratedLine(
            payload.phrase,
            stripFieldLabels: true
        )
        guard !phrase.isEmpty else { return nil }
        return LLMCollocation(
            phrase: phrase,
            gloss: payload.gloss.map {
                normalizeGeneratedLine(
                    $0,
                    stripFieldLabels: true
                )
            }?.nilIfEmpty,
            anchor: normalizeAnchor(payload.anchor)
        )
    }

    private static func normalizeAnchor(_ anchor: LLMAnchorSnapshot?) -> LLMAnchorSnapshot? {
        guard let anchor else { return nil }
        let text = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return LLMAnchorSnapshot(
            text: text,
            note: anchor.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Errors

public enum LLMServiceError: Error, LocalizedError {
    case serverNotAvailable
    case noModelSelected
    case modelNotDownloaded
    case invalidStructuredOutput(String)

    public var errorDescription: String? {
        switch self {
        case .serverNotAvailable: return "Inference server is not available"
        case .noModelSelected: return "No model selected"
        case .modelNotDownloaded: return "Selected model has not been downloaded yet"
        case .invalidStructuredOutput(let message): return message
        }
    }
}
