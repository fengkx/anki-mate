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
    private static let recallDebugEnvironmentKey = "DICTKIT_LLM_RECALL_DEBUG"
    static let exampleArtifactMinTokens = 1024
    static let usageHintMinTokens = 1024
    static let learningAidsMaxTokens = 1024
    static let learningAidJudgeMaxTokens = 1024
    static let learningAidCombinedJudgeMaxTokens = 1024
    static let ipaMaxTokens = 1024
    static let pronunciationEnhancementMaxTokens = 1024
    static let recallPlanMaxTokens = 1024
    static let recallDraftMaxTokens = 1024

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
    private var loadedModelPath: String?
    /// Port of the llama-server child process for direct chat completion requests.
    @Published public private(set) var llamaServerPort: Int?

    public convenience init(
        defaults: UserDefaults = .standard,
        rpcClientConfiguration: RPCClient.Configuration = .init()
    ) {
        let client = RPCClient(configuration: rpcClientConfiguration)
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
            loadedModelPath = modelPath

            // Discover the inference port from health response
            let healthResult: HealthResult = try await rpcClient.call(
                method: RPCMethod.health,
                params: HealthParams(),
                port: port
            )
            llamaServerPort = healthResult.inferencePort

            defaults.set(model.id, forKey: Self.lastSuccessfulModelIdDefaultsKey)
        }
    }

    /// Stop the server.
    public func stopServer() async {
        await serverManager.stop()
        loadedModelId = nil
        loadedModelPath = nil
        llamaServerPort = nil
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
        let port = try requireInferencePort()

        let prompt = LLMPrompt.exampleSentences(
            word: word,
            senses: senses
        )
        let sentenceCount = LLMPrompt.exampleSentenceCount(for: senses)

        let response = try await rpcClient.chatCompletion(
            request: ChatCompletionRequest(
                model: loadedModelPath ?? "",
                messages: [
                    ChatMessage(role: "system", content: prompt.system),
                    ChatMessage(role: "user", content: prompt.user),
                ],
                temperature: adjustedTemperature(0.7),
                max_tokens: max(300, sentenceCount * 96)
            ),
            port: port
        )

        // Parse numbered sentences
        return parseSentences(response.choices.first?.message.content ?? "")
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
        let desiredCount = LLMPrompt.exampleSentenceCount(for: senses)
        let initialExamples = try await requestExampleSentenceArtifacts(
            word: word,
            senses: senses,
            desiredCount: desiredCount,
            temperature: 0.45
        )

        guard senses.count > 1 else {
            return initialExamples
        }

        let coveredSenseIndexes = Set(initialExamples.compactMap(\.senseIndex))
        let missingSenseIndexes = Array(Set(1...senses.count).subtracting(coveredSenseIndexes)).sorted()
        guard !missingSenseIndexes.isEmpty else {
            return initialExamples
        }

        let missingSenses = missingSenseIndexes.map { senses[$0 - 1] }
        let remappedTopUpExamples = try await requestExampleSentenceArtifacts(
            word: word,
            senses: missingSenses,
            desiredCount: missingSenseIndexes.count,
            temperature: 0.2
        )
        let topUpExamples: [LLMExampleSentence] = remappedTopUpExamples.compactMap { example in
            guard let localSenseIndex = example.senseIndex,
                  missingSenseIndexes.indices.contains(localSenseIndex - 1) else {
                return nil
            }

            return LLMExampleSentence(
                english: example.english,
                translation: example.translation,
                senseIndex: missingSenseIndexes[localSenseIndex - 1]
            )
        }

        return Self.mergeExampleSentences(
            initialExamples,
            topUp: topUpExamples,
            desiredCount: desiredCount
        )
    }

    private func requestExampleSentenceArtifacts(
        word: String,
        senses: [LLMSensePromptInput],
        desiredCount: Int,
        temperature: Float
    ) async throws -> [LLMExampleSentence] {
        let prompt = LLMPrompt.exampleSentenceArtifacts(
            word: word,
            senses: senses,
            desiredCount: desiredCount
        )

        let response: ExampleSentenceEnvelope = try await generateStructuredOutput(
            type: ExampleSentenceEnvelope.self,
            prompt: prompt,
            maxTokens: max(Self.exampleArtifactMinTokens, desiredCount * 256),
            temperature: adjustedTemperature(temperature),
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
        let port = try requireInferencePort()

        let prompt = LLMPrompt.exampleSentences(
            word: word,
            senses: senses
        )
        let sentenceCount = LLMPrompt.exampleSentenceCount(for: senses)

        let response = try await rpcClient.chatCompletionStream(
            request: ChatCompletionRequest(
                model: loadedModelPath ?? "",
                messages: [
                    ChatMessage(role: "system", content: prompt.system),
                    ChatMessage(role: "user", content: prompt.user),
                ],
                temperature: adjustedTemperature(0.7),
                max_tokens: max(360, sentenceCount * 112),
                stream: true
            ),
            port: port,
            onDelta: onDelta
        )
        return parseSentences(response.choices.first?.message.content ?? "")
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
        let port = try requireInferencePort()

        let prompt = LLMPrompt.legacyOptimizeDefinitionText(
            word: word,
            senses: senses
        )
        let hintCount = LLMPrompt.usageHintCount(for: senses)

        let response = try await rpcClient.chatCompletionStream(
            request: ChatCompletionRequest(
                model: loadedModelPath ?? "",
                messages: [
                    ChatMessage(role: "system", content: prompt.system),
                    ChatMessage(role: "user", content: prompt.user),
                ],
                temperature: adjustedTemperature(0.5),
                max_tokens: max(260, hintCount * 104),
                stream: true
            ),
            port: port,
            onDelta: onDelta
        )
        return normalizeLegacyUsageHints(response.choices.first?.message.content ?? "")
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
            maxTokens: max(Self.usageHintMinTokens, desiredCount * 192),
            temperature: adjustedTemperature(0.35),
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
            maxTokens: Self.ipaMaxTokens,
            temperature: adjustedTemperature(0.2)
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
            maxTokens: Self.pronunciationEnhancementMaxTokens,
            temperature: adjustedTemperature(strictSpellingRetry ? 0.1 : 0.2)
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
        context: LLMRecallGenerationContext,
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
            context: context,
            mode: mode,
            anchor: anchor
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

    public func generateRecallCardDraftDecision(
        word: String,
        definition: String,
        partOfSpeech: String,
        context: LLMRecallGenerationContext,
        allowedModes: [LLMRecallCardMode],
        modePrior: LLMRecallCardMode? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> RecallCardDraftDecisionEnvelope {
        try await generateRecallCardDraftDecision(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ],
            context: context,
            allowedModes: allowedModes,
            modePrior: modePrior,
            anchor: anchor
        )
    }

    public func generateRecallCardDraftDecision(
        word: String,
        senses: [LLMSensePromptInput],
        context: LLMRecallGenerationContext,
        allowedModes: [LLMRecallCardMode],
        modePrior: LLMRecallCardMode? = nil,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> RecallCardDraftDecisionEnvelope {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSenses = normalizedRecallSenses(senses)
        let normalizedAllowedModes = Self.normalizeAllowedRecallModes(
            allowedModes,
            word: normalizedWord
        )
        let normalizedContext = Self.normalizeRecallGenerationContext(context)
        let normalizedModePrior = Self.normalizeModePrior(
            modePrior,
            allowedModes: normalizedAllowedModes
        )
        let scaffold = Self.recallPromptScaffold(
            word: normalizedWord,
            senses: normalizedSenses
        )
        let wordSignals = Self.recallWordSignals(for: normalizedWord)

        let plan: (
            selectedMode: LLMRecallCardMode,
            selectionReason: LLMRecallSelectionReason,
            cuePlan: LLMRecallCuePlan
        )
        do {
            let planPrompt = LLMPrompt.recallCardPlan(
                word: normalizedWord,
                senses: normalizedSenses,
                context: normalizedContext,
                allowedModes: normalizedAllowedModes,
                modePrior: normalizedModePrior,
                anchor: anchor,
                wordSignals: wordSignals,
                scaffold: scaffold
            )
            let planResponse: RecallCardPlanPayload = try await generateStructuredOutput(
                type: RecallCardPlanPayload.self,
                prompt: planPrompt,
                maxTokens: Self.recallPlanMaxTokens,
                temperature: adjustedTemperature(0.25),
                responseFormat: Self.recallPlanResponseFormat(allowedModes: normalizedAllowedModes),
                operation: "Recall plan generation"
            )
            guard let normalizedPlan = Self.normalizeRecallCardPlan(
                planResponse,
                allowedModes: normalizedAllowedModes,
                target: normalizedWord
            ) else {
                throw LLMServiceError.invalidStructuredOutput(
                    "Recall plan generation returned no valid plan JSON"
                )
            }
            plan = normalizedPlan
        } catch {
            if let fallback = Self.ruleBasedRecallCardDraft(
                word: normalizedWord,
                senses: normalizedSenses,
                mode: normalizedModePrior ?? normalizedAllowedModes.first ?? .fullSpelling,
                anchor: anchor
            ) {
                return RecallCardDraftDecisionEnvelope(
                    draft: fallback,
                    selectionReason: Self.fallbackSelectionReason(for: fallback.mode),
                    cuePlan: Self.fallbackCuePlan(for: fallback, senses: normalizedSenses)
                )
            }
            throw error
        }

        let draftPrompt = LLMPrompt.recallCardDraftFromPlan(
            word: normalizedWord,
            selectedMode: plan.selectedMode,
            primaryGoal: plan.selectionReason.primaryGoal,
            cuePlan: plan.cuePlan,
            anchor: anchor,
            wordSignals: wordSignals,
            scaffold: scaffold
        )
        let draftResponse: RecallCardDecisionPayload = try await generateStructuredOutput(
            type: RecallCardDecisionPayload.self,
            prompt: draftPrompt,
            maxTokens: Self.recallDraftMaxTokens,
            temperature: adjustedTemperature(0.2),
            responseFormat: Self.recallDraftResponseFormat(mode: plan.selectedMode),
            allowReasoningFallback: false,
            operation: "Recall draft generation"
        )
        guard let draftPayload = draftResponse.draft,
              let draft = Self.normalizeRecallCardDraft(
                draftPayload,
                allowedModes: [plan.selectedMode],
                target: normalizedWord
              ) else {
            throw LLMServiceError.invalidStructuredOutput(
                "Recall draft generation returned no valid draft JSON"
            )
        }
        let enforcedDraft = Self.enforceRecallDraftContract(
            draft,
            fallbackAnchor: anchor
        )
        return RecallCardDraftDecisionEnvelope(
            draft: enforcedDraft,
            selectionReason: plan.selectionReason,
            cuePlan: plan.cuePlan
        )
    }

    public func generateRecallCardDraft(
        word: String,
        senses: [LLMSensePromptInput],
        context: LLMRecallGenerationContext,
        mode: LLMRecallCardMode,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMRecallCardDraft {
        let decision = try await generateRecallCardDraftDecision(
            word: word,
            senses: senses,
            context: context,
            allowedModes: [mode],
            modePrior: mode,
            anchor: anchor
        )
        return decision.draft
    }

    public func generateRecallCardDraft(
        word: String,
        senses: [LLMSensePromptInput],
        mode: LLMRecallCardMode,
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMRecallCardDraft {
        try await generateRecallCardDraft(
            word: word,
            senses: senses,
            context: .init(),
            mode: mode,
            anchor: anchor
        )
    }

    public func generateLearningAids(
        word: String,
        definition: String,
        partOfSpeech: String,
        acceptedContext: LLMLearningAidAcceptedContext = .init(),
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
            acceptedContext: acceptedContext,
            anchor: anchor
        )
    }

    public func generateLearningAids(
        word: String,
        senses: [LLMSensePromptInput],
        acceptedContext: LLMLearningAidAcceptedContext = .init(),
        anchor: LLMAnchorSnapshot? = nil
    ) async throws -> LLMLearningAids {
        let prompt = LLMPrompt.learningAids(
            word: word,
            senses: senses,
            acceptedContext: Self.normalizeLearningAidAcceptedContext(acceptedContext),
            anchor: anchor
        )

        let response: LearningAidsEnvelope = try await generateStructuredOutput(
            type: LearningAidsEnvelope.self,
            prompt: prompt,
            maxTokens: Self.learningAidsMaxTokens,
            temperature: adjustedTemperature(0.4),
            responseFormat: LLMResponseFormat(kind: .json)
        )

        return Self.filterLearningAids(
            Self.normalizeLearningAids(response),
            word: word,
            senses: senses
        )
    }

    public func generateRankedLearningAids(
        word: String,
        senses: [LLMSensePromptInput],
        acceptedContext: LLMLearningAidAcceptedContext,
        anchor: LLMAnchorSnapshot? = nil,
        judgeStrategy: LLMLearningAidJudgeStrategy = .separateSections
    ) async throws -> LLMLearningAidsRankedResult {
        let aids = try await generateLearningAids(
            word: word,
            senses: senses,
            acceptedContext: acceptedContext,
            anchor: anchor
        )

        return await rankLearningAids(
            aids,
            word: word,
            senses: senses,
            acceptedContext: acceptedContext,
            judgeStrategy: judgeStrategy
        )
    }

    func rankLearningAids(
        _ aids: LLMLearningAids,
        word: String,
        senses: [LLMSensePromptInput],
        acceptedContext: LLMLearningAidAcceptedContext,
        judgeStrategy: LLMLearningAidJudgeStrategy = .separateSections
    ) async -> LLMLearningAidsRankedResult {
        let normalizedContext = Self.normalizeLearningAidAcceptedContext(acceptedContext)
        let selections: LLMLearningAidSelections

        switch judgeStrategy {
        case .separateSections:
            async let pitfallSelection = rankLearningAidSection(
                .pitfalls,
                word: word,
                senses: senses,
                aids: aids,
                acceptedContext: normalizedContext
            )
            async let mnemonicSelection = rankLearningAidSection(
                .mnemonics,
                word: word,
                senses: senses,
                aids: aids,
                acceptedContext: normalizedContext
            )
            async let collocationSelection = rankLearningAidSection(
                .collocations,
                word: word,
                senses: senses,
                aids: aids,
                acceptedContext: normalizedContext
            )

            selections = await LLMLearningAidSelections(
                pitfalls: pitfallSelection,
                mnemonics: mnemonicSelection,
                collocations: collocationSelection
            )

        case .combinedSections:
            selections = await rankLearningAidSectionsCombined(
                word: word,
                senses: senses,
                aids: aids,
                acceptedContext: normalizedContext
            )
        }

        return LLMLearningAidsRankedResult(
            aids: Self.reorderLearningAids(aids, selections: selections),
            selections: selections
        )
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

    private func normalizedRecallSenses(_ senses: [LLMSensePromptInput]) -> [LLMSensePromptInput] {
        let normalized = senses.compactMap { sense -> LLMSensePromptInput? in
            let partOfSpeech = sense.partOfSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
            let definition = sense.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !definition.isEmpty else { return nil }
            return LLMSensePromptInput(
                partOfSpeech: partOfSpeech.isEmpty ? "general" : partOfSpeech,
                definition: definition,
                semanticHint: sense.semanticHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            )
        }

        return normalized.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : normalized
    }

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

    static func mergeExampleSentences(
        _ primary: [LLMExampleSentence],
        topUp: [LLMExampleSentence],
        desiredCount: Int
    ) -> [LLMExampleSentence] {
        var merged: [LLMExampleSentence] = []
        var seenEnglish = Set<String>()
        var coveredSenseIndexes = Set<Int>()

        func appendIfNeeded(_ example: LLMExampleSentence) {
            guard !seenEnglish.contains(example.english) else { return }
            merged.append(example)
            seenEnglish.insert(example.english)
            if let senseIndex = example.senseIndex {
                coveredSenseIndexes.insert(senseIndex)
            }
        }

        for example in primary {
            guard let senseIndex = example.senseIndex,
                  !coveredSenseIndexes.contains(senseIndex) else {
                continue
            }
            appendIfNeeded(example)
        }

        for example in topUp {
            guard let senseIndex = example.senseIndex,
                  !coveredSenseIndexes.contains(senseIndex) else {
                continue
            }
            appendIfNeeded(example)
        }

        for example in primary + topUp {
            guard merged.count < desiredCount else { break }
            appendIfNeeded(example)
        }

        return Array(merged.prefix(desiredCount))
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
        responseFormat: LLMResponseFormat? = nil,
        allowReasoningFallback: Bool = true,
        operation: String = "Structured generation"
    ) async throws -> T {
        try await ensureReady()
        let port = try requireInferencePort()

        let response = try await rpcClient.chatCompletion(
            request: ChatCompletionRequest(
                model: loadedModelPath ?? "",
                messages: [
                    ChatMessage(role: "system", content: prompt.system),
                    ChatMessage(role: "user", content: prompt.user),
                ],
                temperature: temperature,
                max_tokens: maxTokens,
                response_format: responseFormat.flatMap { Self.mapResponseFormat($0) }
            ),
            port: port
        )

        let responseText = try Self.strictStructuredResponseText(
            from: response,
            operation: operation,
            allowReasoningFallback: allowReasoningFallback
        )
        return try Self.decodeStructuredOutput(type, from: responseText)
    }

    /// OpenAI-style chat generation entry point.
    ///
    /// Sends a `/v1/chat/completions` request to the server. When `tools` is
    /// non-empty, the upstream llama-server handles tool-call parsing and
    /// returns any model-emitted tool calls; otherwise it behaves like a plain
    /// chat completion.
    public func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool = false,
        responseFormat: LLMResponseFormat? = nil,
        maxTokens: Int? = nil,
        temperature: Float = 0.2
    ) async throws -> GenerateResult {
        try await ensureReady()
        let port = try requireInferencePort()

        let chatMessages = messages.map { ChatMessage(role: $0.role.rawValue, content: $0.content) }

        let chatTools: [ChatTool]? = tools.flatMap { defs in
            let mapped = defs.map { tool in
                ChatTool(
                    function: ChatFunction(
                        name: tool.name,
                        description: tool.description,
                        parameters: tool.parameters
                    )
                )
            }
            return mapped.isEmpty ? nil : mapped
        }

        let chatToolChoice: JSONValue? = if let toolChoice {
            .string(toolChoice)
        } else if chatTools != nil {
            .string("auto")
        } else {
            nil
        }

        let response = try await rpcClient.chatCompletion(
            request: ChatCompletionRequest(
                model: loadedModelPath ?? "",
                messages: chatMessages,
                temperature: temperature,
                max_tokens: maxTokens,
                tools: chatTools,
                tool_choice: chatToolChoice,
                parallel_tool_calls: (chatTools != nil) ? parallelToolCalls : nil,
                response_format: responseFormat.flatMap { Self.mapResponseFormat($0) }
            ),
            port: port
        )

        return Self.mapToGenerateResult(response)
    }

    /// Streaming variant of `generate`. Calls `onDelta` for each content chunk.
    public func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]? = nil,
        toolChoice: String? = nil,
        parallelToolCalls: Bool = false,
        maxTokens: Int? = nil,
        temperature: Float = 0.2,
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> GenerateResult {
        try await ensureReady()
        let port = try requireInferencePort()

        let chatMessages = messages.map { ChatMessage(role: $0.role.rawValue, content: $0.content) }

        let chatTools: [ChatTool]? = tools.flatMap { defs in
            let mapped = defs.map { tool in
                ChatTool(
                    function: ChatFunction(
                        name: tool.name,
                        description: tool.description,
                        parameters: tool.parameters
                    )
                )
            }
            return mapped.isEmpty ? nil : mapped
        }

        let chatToolChoice: JSONValue? = if let toolChoice {
            .string(toolChoice)
        } else if chatTools != nil {
            .string("auto")
        } else {
            nil
        }

        let response = try await rpcClient.chatCompletionStream(
            request: ChatCompletionRequest(
                model: loadedModelPath ?? "",
                messages: chatMessages,
                temperature: temperature,
                max_tokens: maxTokens,
                stream: true,
                tools: chatTools,
                tool_choice: chatToolChoice,
                parallel_tool_calls: (chatTools != nil) ? parallelToolCalls : nil
            ),
            port: port,
            onDelta: onDelta,
            onReasoningDelta: onReasoningDelta
        )

        return Self.mapToGenerateResult(response)
    }

    /// Returns the llama-server child port for direct chat completion requests.
    /// Call `ensureReady()` first — this throws if the port is not available.
    private func requireInferencePort() throws -> Int {
        guard let port = llamaServerPort else {
            throw LLMServiceError.serverNotAvailable
        }
        return port
    }

    private func adjustedTemperature(_ base: Float) -> Float {
        LLMContentStyle.current(defaults: defaults).adjustedTemperature(base)
    }

    public static func normalizeRecallGenerationContext(
        _ context: LLMRecallGenerationContext
    ) -> LLMRecallGenerationContext {
        LLMRecallGenerationContext(
            acceptedPitfalls: normalizeRecallTextItems(context.acceptedPitfalls, limit: 2),
            acceptedUsageHints: normalizeRecallTextItems(context.acceptedUsageHints, limit: 2),
            acceptedMnemonics: normalizeRecallTextItems(context.acceptedMnemonics, limit: 1),
            acceptedCollocations: normalizeRecallTextItems(context.acceptedCollocations, limit: 2)
        )
    }

    public static func recallWordSignals(for word: String) -> LLMRecallWordSignals {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalizedWord.lowercased()
        let repeatedLetters = hasRepeatedLetter(in: lowercased)
        let confusableVowelClusters = ["ie", "ei", "ea", "oa", "ou", "io", "ae", "oe"]
        let hasConfusableVowelCluster = confusableVowelClusters.contains { lowercased.contains($0) }

        return LLMRecallWordSignals(
            isPhrase: normalizedWord.contains(" "),
            hasRepeatedLetters: repeatedLetters,
            hasConfusableVowelCluster: hasConfusableVowelCluster
        )
    }

    public static func normalizeAllowedRecallModes(
        _ allowedModes: [LLMRecallCardMode],
        word: String
    ) -> [LLMRecallCardMode] {
        var seen = Set<LLMRecallCardMode>()
        let uniqueModes = allowedModes.filter { seen.insert($0).inserted }
        if !uniqueModes.isEmpty {
            return uniqueModes
        }
        return word.contains(" ") ? [.phraseRecall] : [.fullSpelling]
    }

    public static func normalizeModePrior(
        _ modePrior: LLMRecallCardMode?,
        allowedModes: [LLMRecallCardMode]
    ) -> LLMRecallCardMode? {
        guard let modePrior else { return allowedModes.first }
        return allowedModes.contains(modePrior) ? modePrior : allowedModes.first
    }

    public static func recommendedRecallAllowedModes(
        for word: String,
        context: LLMRecallGenerationContext
    ) -> [LLMRecallCardMode] {
        let normalizedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedWord.contains(" ") {
            return [.phraseRecall]
        }

        let normalizedContext = normalizeRecallGenerationContext(context)
        let signals = recallWordSignals(for: normalizedWord)
        let hasLocalSpellingEvidence = normalizedContext.acceptedPitfalls.contains {
            seemsLikeLocalSpellingPitfall($0)
        }

        if hasLocalSpellingEvidence || signals.hasRepeatedLetters || signals.hasConfusableVowelCluster {
            return [.fullSpelling, .targetedLetterCloze]
        }
        return [.fullSpelling]
    }

    public static func recommendedRecallModePrior(
        for word: String,
        context: LLMRecallGenerationContext,
        allowedModes: [LLMRecallCardMode]? = nil
    ) -> LLMRecallCardMode? {
        let resolvedAllowedModes = normalizeAllowedRecallModes(
            allowedModes ?? recommendedRecallAllowedModes(for: word, context: context),
            word: word
        )
        if resolvedAllowedModes == [.phraseRecall] {
            return .phraseRecall
        }

        let normalizedContext = normalizeRecallGenerationContext(context)
        if normalizedContext.acceptedPitfalls.contains(where: seemsLikeLocalSpellingPitfall),
           resolvedAllowedModes.contains(.targetedLetterCloze) {
            return .targetedLetterCloze
        }

        return resolvedAllowedModes.first
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
        // Keep the user's current selection if it is still valid; only fall back
        // to the last successful model when the current selection is missing.
        if downloadedModelIDs.contains(currentSelectedModelId) {
            return currentSelectedModelId
        }
        if let lastSuccessfullyLoadedModelId,
           downloadedModelIDs.contains(lastSuccessfullyLoadedModelId) {
            return lastSuccessfullyLoadedModelId
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

struct RecallCardPlanPayload: Decodable {
    let selectedMode: String
    let selectionReason: RecallSelectionReasonPayload?
    let cuePlan: RecallCuePlanPayload?

    private enum CodingKeys: String, CodingKey {
        case selectedMode
        case mode
        case selectionReason
        case cuePlan
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedMode =
            try container.decodeIfPresent(String.self, forKey: .selectedMode)
            ?? container.decodeIfPresent(String.self, forKey: .mode)
            ?? ""
        self.selectionReason = try container.decodeIfPresent(RecallSelectionReasonPayload.self, forKey: .selectionReason)
        self.cuePlan = try container.decodeIfPresent(RecallCuePlanPayload.self, forKey: .cuePlan)
    }
}

struct RecallCardDecisionPayload: Decodable {
    let draft: RecallCardDraftPayload?

    private enum CodingKeys: String, CodingKey {
        case draft
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

struct RecallSelectionReasonPayload: Decodable {
    let primaryGoal: String
    let evidence: [String]

    private enum CodingKeys: String, CodingKey {
        case primaryGoal
        case evidence
    }
}

struct RecallCuePlanPayload: Decodable {
    let semanticSource: String
    let normalizedCue: String

    private enum CodingKeys: String, CodingKey {
        case semanticSource
        case normalizedCue
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
    let translation: String?
    let category: String?
    let focus: String?
    let recallRelevant: Bool?
    let senseIndex: Int?
    let details: String?
    let anchor: LLMAnchorSnapshot?
}

struct MnemonicPayload: Decodable {
    let clue: String
    let translation: String?
    let kind: String?
    let focus: String?
    let recallRelevant: Bool?
    let senseIndex: Int?
    let anchor: LLMAnchorSnapshot?
}

struct CollocationPayload: Decodable {
    let phrase: String
    let gloss: String?
    let focus: String?
    let recallRelevant: Bool?
    let senseIndex: Int?
    let anchor: LLMAnchorSnapshot?
}

struct LearningAidJudgeEnvelope: Decodable {
    let recommendedId: String?
    let alternativeIds: [String]
    let overlapHints: [LearningAidJudgeOverlapHintPayload]
    let whyRecommended: String?
}

struct LearningAidCombinedJudgeEnvelope: Decodable {
    let pitfalls: LearningAidJudgeEnvelope?
    let mnemonics: LearningAidJudgeEnvelope?
    let collocations: LearningAidJudgeEnvelope?
}

struct LearningAidJudgeOverlapHintPayload: Decodable {
    let candidateId: String
    let overlapType: String?
    let withItemId: String?
    let reason: String
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

        let rawPreview = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(400)
        let candidatePreview = attemptedPayloads.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(400)

        throw LLMServiceError.invalidStructuredOutput(
            [
                "Expected JSON object for structured output",
                rawPreview.isEmpty ? nil : "raw=\(rawPreview)",
                candidatePreview.map { "candidate=\($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: " | ")
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

    static func normalizeRecallCardPlan(
        _ payload: RecallCardPlanPayload,
        allowedModes: [LLMRecallCardMode],
        target: String
    ) -> (selectedMode: LLMRecallCardMode, selectionReason: LLMRecallSelectionReason, cuePlan: LLMRecallCuePlan)? {
        guard let selectedMode = normalizedRecallCardMode(from: payload.selectedMode),
              allowedModes.contains(selectedMode),
              let cuePlan = normalizeRecallCuePlan(
                  payload.cuePlan,
                  target: target
              ) else {
            return nil
        }
        return (
            selectedMode,
            fallbackSelectionReason(for: selectedMode),
            cuePlan
        )
    }

    static func normalizeLearningAids(_ payload: LearningAidsEnvelope) -> LLMLearningAids {
        LLMLearningAids(
            pitfalls: payload.pitfalls.compactMap(normalizePitfall),
            mnemonics: payload.mnemonics.compactMap(normalizeMnemonic),
            collocations: payload.collocations.compactMap(normalizeCollocation)
        )
    }

    static func filterLearningAids(
        _ aids: LLMLearningAids,
        word: String,
        senses: [LLMSensePromptInput]
    ) -> LLMLearningAids {
        LLMLearningAids(
            pitfalls: aids.pitfalls.filter {
                !Self.isLowIncrementLearningAidCandidate(
                    section: LLMLearningAidSection.pitfalls,
                    word: word,
                    text: $0.summary,
                    translation: $0.translation,
                    type: $0.category,
                    focus: $0.focus,
                    recallRelevant: $0.recallRelevant,
                    senses: senses
                )
            },
            mnemonics: aids.mnemonics.filter {
                !Self.isLowIncrementLearningAidCandidate(
                    section: LLMLearningAidSection.mnemonics,
                    word: word,
                    text: $0.clue,
                    translation: $0.translation,
                    type: $0.kind,
                    focus: $0.focus,
                    recallRelevant: $0.recallRelevant,
                    senses: senses
                )
            },
            collocations: aids.collocations.filter {
                !Self.isLowIncrementLearningAidCandidate(
                    section: LLMLearningAidSection.collocations,
                    word: word,
                    text: $0.phrase,
                    translation: $0.gloss,
                    type: "collocation",
                    focus: $0.focus,
                    recallRelevant: $0.recallRelevant,
                    senses: senses
                )
            }
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

    private static func normalizeRecallTextItems(
        _ values: [String],
        limit: Int
    ) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !normalized.isEmpty else { return nil }
            let limited = normalized.count > 120
                ? String(normalized.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
                : normalized
            let key = limited.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return limited
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func seemsLikeLocalSpellingPitfall(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let keywords = [
            "spell", "spelling", "letter", "letters", "double", "vowel", "consonant",
            "suffix", "prefix", "顺序", "拼写", "字母", "双写", "元音", "辅音", "漏掉", "写反"
        ]
        return keywords.contains { normalized.contains($0) }
    }

    private static func recallPlanResponseFormat(
        allowedModes: [LLMRecallCardMode]
    ) -> LLMResponseFormat {
        LLMResponseFormat(
            kind: .jsonSchema,
            schema: recallPlanSchema(allowedModes: allowedModes),
            strict: true
        )
    }

    private static func recallDraftResponseFormat(
        mode: LLMRecallCardMode
    ) -> LLMResponseFormat {
        LLMResponseFormat(
            kind: .jsonSchema,
            schema: recallDraftSchema(mode: mode),
            strict: true
        )
    }

    private static func recallPlanSchema(
        allowedModes: [LLMRecallCardMode]
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("selectedMode"), .string("cuePlan")]),
            "properties": .object([
                "selectedMode": .object([
                    "type": .string("string"),
                    "enum": .array(allowedModes.map { .string($0.rawValue) })
                ]),
                "cuePlan": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([.string("semanticSource"), .string("normalizedCue")]),
                    "properties": .object([
                        "semanticSource": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("accepted_usage_hint"),
                                .string("sense_semantic_hint"),
                                .string("sense_definition_paraphrase"),
                                .string("pitfall"),
                                .string("collocation")
                            ])
                        ]),
                        "normalizedCue": .object([
                            "type": .string("string"),
                            "maxLength": .number(120)
                        ])
                    ])
                ])
            ])
        ])
    }

    private static func recallDraftSchema(
        mode: LLMRecallCardMode
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "required": .array([.string("draft")]),
            "properties": .object([
                "draft": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "required": .array([
                        .string("mode"),
                        .string("front"),
                        .string("back")
                    ]),
                    "properties": .object([
                        "mode": .object([
                            "type": .string("string"),
                            "enum": .array([.string(mode.rawValue)])
                        ]),
                        "front": .object([
                            "type": .string("string"),
                            "maxLength": .number(120)
                        ]),
                        "back": .object([
                            "type": .string("string"),
                            "maxLength": .number(120)
                        ]),
                        "hint": .object([
                            "type": .string("string"),
                            "maxLength": .number(80)
                        ]),
                        "anchor": .object([
                            "type": .string("object"),
                            "additionalProperties": .bool(false),
                            "required": .array([.string("text")]),
                            "properties": .object([
                                "text": .object([
                                    "type": .string("string"),
                                    "maxLength": .number(160)
                                ]),
                                "note": .object([
                                    "type": .string("string"),
                                    "maxLength": .number(160)
                                ])
                            ])
                        ])
                    ])
                ])
            ])
        ])
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
        normalizeRecallCardDraft(
            payload,
            allowedModes: [expectedMode],
            target: target
        )
    }

    private static func normalizeRecallCardDraft(
        _ payload: RecallCardDraftPayload,
        allowedModes: [LLMRecallCardMode],
        target: String
    ) -> LLMRecallCardDraft? {
        guard let mode = normalizedRecallCardMode(from: payload.mode),
              allowedModes.contains(mode) else {
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

        let hint = payload.hint.map {
            normalizeGeneratedLine(
                $0,
                stripFieldLabels: true
            )
        }?.nilIfEmpty

        if mode == .targetedLetterCloze {
            guard isValidTargetedLetterClozeSurface(front, hint: hint, target: target) else {
                return nil
            }
        }
        let anchor = normalizeAnchor(payload.anchor)
        return LLMRecallCardDraft(
            mode: mode,
            front: front,
            back: back,
            hint: hint,
            anchor: anchor
        )
    }

    static func enforceRecallDraftContract(
        _ draft: LLMRecallCardDraft,
        fallbackAnchor: LLMAnchorSnapshot?
    ) -> LLMRecallCardDraft {
        return LLMRecallCardDraft(
            mode: draft.mode,
            front: draft.front,
            back: draft.back,
            hint: draft.hint?.nilIfEmpty,
            anchor: draft.anchor ?? normalizeAnchor(fallbackAnchor)
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
            senses: senses
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

    private static func normalizeRecallSelectionReason(
        _ payload: RecallSelectionReasonPayload?,
        selectedMode: LLMRecallCardMode
    ) -> LLMRecallSelectionReason? {
        guard let payload else { return nil }
        let primaryGoal = normalizeGeneratedLine(payload.primaryGoal, stripFieldLabels: true)
        guard !primaryGoal.isEmpty,
              isAllowedRecallPrimaryGoal(primaryGoal) else {
            return nil
        }

        let evidence = payload.evidence
            .map { normalizeGeneratedLine($0, stripFieldLabels: true) }
            .filter { !$0.isEmpty }
        guard !evidence.isEmpty else { return nil }

        return LLMRecallSelectionReason(
            primaryGoal: primaryGoal,
            evidence: Array(evidence.prefix(3))
        )
    }

    private static func normalizeRecallCuePlan(
        _ payload: RecallCuePlanPayload?,
        target: String
    ) -> LLMRecallCuePlan? {
        guard let payload else { return nil }
        let semanticSource = normalizeGeneratedLine(payload.semanticSource, stripFieldLabels: true)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let allowedSources: Set<String> = [
            "accepted_usage_hint",
            "sense_semantic_hint",
            "sense_definition_paraphrase",
            "pitfall",
            "collocation"
        ]
        guard allowedSources.contains(semanticSource) else { return nil }

        let normalizedCue = normalizeGeneratedLine(payload.normalizedCue, stripFieldLabels: true)
        guard !normalizedCue.isEmpty, normalizedCue != target else { return nil }
        guard !recallCueContainsTarget(normalizedCue, target: target) else { return nil }

        return LLMRecallCuePlan(
            semanticSource: semanticSource,
            normalizedCue: normalizedCue
        )
    }

    private static func recallCueContainsTarget(_ cue: String, target: String) -> Bool {
        let trimmedCue = cue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCue.isEmpty, !trimmedTarget.isEmpty else { return false }

        let normalizedCue = trimmedCue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedTarget = trimmedTarget.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if normalizedTarget.contains(" ") {
            return normalizedCue.contains(normalizedTarget)
        }

        let pattern = #"(?<![[:alnum:]])\#(NSRegularExpression.escapedPattern(for: normalizedTarget))(?![[:alnum:]])"#
        return normalizedCue.range(of: pattern, options: .regularExpression) != nil
    }

    private static func fallbackSelectionReason(for mode: LLMRecallCardMode) -> LLMRecallSelectionReason {
        switch mode {
        case .fullSpelling:
            return LLMRecallSelectionReason(
                primaryGoal: "whole_word_recall",
                evidence: ["fallback selected a whole-word recall card"]
            )
        case .targetedLetterCloze:
            return LLMRecallSelectionReason(
                primaryGoal: "local_spelling_calibration",
                evidence: ["fallback selected a local spelling calibration card"]
            )
        case .phraseRecall:
            return LLMRecallSelectionReason(
                primaryGoal: "phrase_chunk_retrieval",
                evidence: ["fallback selected a phrase-level recall card"]
            )
        }
    }

    private static func fallbackCuePlan(
        for draft: LLMRecallCardDraft,
        senses: [LLMSensePromptInput]
    ) -> LLMRecallCuePlan {
        let semanticSource = senses.first?.semanticHint?.nilIfEmpty != nil
            ? "sense_semantic_hint"
            : "sense_definition_paraphrase"
        let normalizedCue = recallPromptScaffold(word: draft.back, senses: senses).learnerCue
            ?? draft.front
        return LLMRecallCuePlan(
            semanticSource: semanticSource,
            normalizedCue: normalizedCue
        )
    }

    private static func isAllowedRecallPrimaryGoal(_ primaryGoal: String) -> Bool {
        [
            "whole_word_recall",
            "local_spelling_calibration",
            "phrase_chunk_retrieval"
        ].contains(primaryGoal)
    }

    private static func isValidTargetedLetterClozeSurface(
        _ front: String,
        hint: String?,
        target: String
    ) -> Bool {
        let combined = [front, hint ?? ""].joined(separator: " ")
        guard front.contains("_") else { return false }
        guard combined.contains("_") else { return false }
        guard underscoreGroupCount(in: combined) == 1 else { return false }
        guard !combined.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("_") else { return false }
        return clozeGapMatchesTarget(front, target: target)
    }

    private static func clozeGapMatchesTarget(_ front: String, target: String) -> Bool {
        let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTarget.isEmpty else { return false }

        for candidate in clozeTokenCandidates(in: front) where underscoreGroupCount(in: candidate) == 1 {
            let gapLength = longestUnderscoreRun(in: candidate)
            guard gapLength > 0 else { continue }
            let parts = splitClozeToken(candidate)
            let prefix = parts.prefix.lowercased()
            let suffix = parts.suffix.lowercased()
            guard !prefix.isEmpty || !suffix.isEmpty else { continue }
            guard normalizedTarget.hasPrefix(prefix),
                  normalizedTarget.hasSuffix(suffix),
                  prefix.count + suffix.count < normalizedTarget.count else {
                continue
            }

            let missingLetterCount = normalizedTarget.count - prefix.count - suffix.count
            if missingLetterCount == gapLength {
                return true
            }
        }
        return false
    }

    private static func clozeTokenCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var current = ""

        func flushCurrent() {
            if current.contains("_") {
                candidates.append(current)
            }
            current.removeAll(keepingCapacity: true)
        }

        for character in text {
            if isClozeTokenCharacter(character) {
                current.append(character)
            } else {
                flushCurrent()
            }
        }
        flushCurrent()

        return candidates
    }

    private static func isClozeTokenCharacter(_ character: Character) -> Bool {
        if character == "_" { return true }
        return character.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar)
        }
    }

    private static func splitClozeToken(_ token: String) -> (prefix: String, suffix: String) {
        guard let firstGap = token.firstIndex(of: "_"),
              let lastGap = token.lastIndex(of: "_") else {
            return (token, "")
        }
        return (
            String(token[..<firstGap]),
            String(token[token.index(after: lastGap)...])
        )
    }

    private static func underscoreGroupCount(in text: String) -> Int {
        var count = 0
        var previousWasUnderscore = false
        for character in text {
            if character == "_" {
                if !previousWasUnderscore {
                    count += 1
                }
                previousWasUnderscore = true
            } else {
                previousWasUnderscore = false
            }
        }
        return count
    }

    private static func longestUnderscoreRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "_" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    private static func hasRepeatedLetter(in text: String) -> Bool {
        var previous: Character?
        for character in text {
            guard character.isLetter else {
                previous = nil
                continue
            }
            if previous == character {
                return true
            }
            previous = character
        }
        return false
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
        senses: [LLMSensePromptInput]
    ) -> RecallPromptScaffold {
        RecallPromptScaffold(
            learnerCue: fallbackRecallCue(from: senses).nilIfEmpty,
            hint: fallbackRecallHint(from: senses)
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
            translation: payload.translation.map {
                normalizeGeneratedLine(
                    $0,
                    stripFieldLabels: true
                )
            }?.nilIfEmpty,
            category: payload.category?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            focus: payload.focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            recallRelevant: payload.recallRelevant,
            senseIndex: payload.senseIndex,
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
            translation: payload.translation.map {
                normalizeGeneratedLine(
                    $0,
                    stripFieldLabels: true
                )
            }?.nilIfEmpty,
            kind: payload.kind?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            focus: payload.focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            recallRelevant: payload.recallRelevant,
            senseIndex: payload.senseIndex,
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
            focus: payload.focus?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            recallRelevant: payload.recallRelevant,
            senseIndex: payload.senseIndex,
            anchor: normalizeAnchor(payload.anchor)
        )
    }

    private static func isLowIncrementLearningAidCandidate(
        section: LLMLearningAidSection,
        word: String,
        text: String,
        translation: String?,
        type: String?,
        focus: String?,
        recallRelevant: Bool?,
        senses: [LLMSensePromptInput]
    ) -> Bool {
        let normalizedText = normalizedLearningAidText(text)
        let normalizedTranslation = translation.map(normalizedLearningAidText)
        let contentTokens = learningAidContentTokens(for: [text, translation].compactMap { $0 })
        let lexicalTokens = lexicalLearningAidTokens(for: text)
        let normalizedWord = normalizedLearningAidText(word)
        let maxOverlap = maxDefinitionOverlap(
            with: [text, translation].compactMap { $0 },
            senses: senses
        )

        if isDefinitionParaphraseLike(maxOverlap: maxOverlap, contentTokens: contentTokens, section: section) {
            return true
        }

        switch section {
        case .pitfalls:
            if normalizedText.contains("confusing with") || normalizedText.contains("confuse with") {
                if !normalizedText.contains(normalizedWord) {
                    return true
                }
            }
            if contentTokens.count <= 3 {
                if let normalizedTranslation,
                   normalizedTranslation.count <= 8,
                   !containsAny(normalizedText, ["spelling", "contrast", "misuse"]) {
                    return true
                }

                let hasSpecificContrastCue = containsAny(normalizedText, pitfallContrastMarkers)
                let hasSpecificEnglishToken = lexicalTokens.contains { token in
                    guard token != normalizedWord else { return false }
                    return !pitfallContrastNoiseTokens.contains(token)
                }

                if hasSpecificContrastCue && (normalizedText.contains(normalizedWord) || hasSpecificEnglishToken) {
                    return false
                }
                return true
            }
            if type == "usage_tendency" && recallRelevant != true {
                return true
            }
            return false

        case .mnemonics:
            if contentTokens.count <= 3 {
                if let normalizedTranslation,
                   normalizedTranslation.count <= 8,
                   !containsAny(normalizedText, mnemonicHookMarkers) {
                    return true
                }
                if containsAny(normalizedText, mnemonicHookMarkers) || normalizedText.contains("=") {
                    return false
                }
                if lexicalTokens.contains(where: mnemonicGlueWords.contains) {
                    return true
                }
                return false
            }
            if !containsAny(normalizedText, mnemonicHookMarkers) && maxOverlap >= 0.45 {
                return true
            }
            return false

        case .collocations:
            if normalizedText.contains(normalizedWord) && contentTokens.count <= 4 {
                return true
            }
            if contentTokens.count <= 2 && maxOverlap >= 0.4 {
                return true
            }
            if contentTokens.count <= 4, maxOverlap >= 0.5 {
                return true
            }
            return false
        }
    }

    private static let pitfallThinMarkers: [String] = [
        "confuse",
        "confusing",
        "mistake",
        "mix up",
        "avoid",
        "spelling",
        "trap",
        "watch out",
        "instead of",
        "rather than"
    ]

    private static let pitfallContrastMarkers: [String] = [
        "confuse",
        "confusing",
        "mistake",
        "mix up",
        "avoid",
        "spelling",
        "trap",
        "watch out",
        "instead of",
        "rather than",
        "not",
        "vs",
        "contrast",
        "区别",
        "对比",
        "不同",
        "混淆",
        "不要",
        "和"
    ]

    private static let pitfallContrastNoiseTokens: Set<String> = [
        "confuse",
        "confusing",
        "mistake",
        "mix",
        "up",
        "avoid",
        "spelling",
        "trap",
        "watch",
        "out",
        "instead",
        "rather",
        "than",
        "not",
        "vs",
        "contrast",
        "with",
        "without",
        "and",
        "or",
        "do",
        "does",
        "did"
    ]

    private static let mnemonicHookMarkers: [String] = [
        "remember",
        "sounds like",
        "sound like",
        "picture",
        "imagine",
        "think of",
        "associate",
        "visual",
        "memory",
        "hook"
    ]

    private static let mnemonicGlueWords: Set<String> = [
        "a",
        "an",
        "the",
        "of",
        "to",
        "for",
        "in",
        "on",
        "at",
        "with",
        "from"
    ]

    private static func containsAny(_ text: String, _ markers: [String]) -> Bool {
        markers.contains { text.contains($0) }
    }

    private static func isDefinitionParaphraseLike(
        maxOverlap: Double,
        contentTokens: [String],
        section: LLMLearningAidSection
    ) -> Bool {
        switch section {
        case .pitfalls:
            return maxOverlap >= 0.55 && contentTokens.count <= 6
        case .mnemonics:
            return maxOverlap >= 0.45 && contentTokens.count <= 5
        case .collocations:
            return maxOverlap >= 0.4 && contentTokens.count <= 4
        }
    }

    private static func maxDefinitionOverlap(
        with candidateTexts: [String],
        senses: [LLMSensePromptInput]
    ) -> Double {
        let candidateTokens = learningAidContentTokens(for: candidateTexts)
        guard !candidateTokens.isEmpty else { return 0 }

        var best: Double = 0
        for sense in senses {
            let senseTokens = learningAidContentTokens(for: [sense.definition, sense.semanticHint].compactMap { $0 })
            guard !senseTokens.isEmpty else { continue }
            let overlap = Double(Set(candidateTokens).intersection(senseTokens).count)
                / Double(max(1, min(candidateTokens.count, senseTokens.count)))
            best = max(best, overlap)

            let normalizedCandidate = candidateTexts.joined(separator: " ").lowercased()
            let normalizedSense = [sense.definition, sense.semanticHint]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()
            if !normalizedCandidate.isEmpty, !normalizedSense.isEmpty,
               (normalizedCandidate.contains(normalizedSense) || normalizedSense.contains(normalizedCandidate)) {
                best = max(best, 1.0)
            }
        }

        return best
    }

    private static func learningAidContentTokens(for texts: [String]) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "as", "be", "by", "for", "from", "in", "is", "it", "of", "or", "the",
            "to", "with", "without", "on", "at", "into", "than", "that", "this", "these", "those",
            "are", "was", "were", "am", "been", "being"
        ]

        return texts
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    private static func lexicalLearningAidTokens(for text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private struct LearningAidJudgeCandidate: Codable {
        let id: String
        let text: String
        let translation: String?
        let type: String?
        let focus: String?
        let recallRelevant: Bool?
        let senseIndex: Int?
    }

    private struct LearningAidJudgeAcceptedItem: Codable {
        let id: String
        let section: String
        let text: String
        let focus: String?
        let recallRelevant: Bool?
    }

    private func rankLearningAidSection(
        _ section: LLMLearningAidSection,
        word: String,
        senses: [LLMSensePromptInput],
        aids: LLMLearningAids,
        acceptedContext: LLMLearningAidAcceptedContext
    ) async -> LLMLearningAidSectionSelection? {
        let candidates = learningAidCandidates(for: section, aids: aids)
        guard !candidates.isEmpty else { return nil }

        do {
            let prompt = LLMPrompt.learningAidJudge(
                section: section,
                word: word,
                senses: senses,
                candidatesJSON: compactJSONString(candidates),
                acceptedJSON: compactJSONString(
                    judgeAcceptedItems(for: acceptedContext)
                )
            )
            let judge: LearningAidJudgeEnvelope = try await generateStructuredOutput(
                type: LearningAidJudgeEnvelope.self,
                prompt: prompt,
                maxTokens: Self.learningAidJudgeMaxTokens,
                temperature: adjustedTemperature(0.2),
                responseFormat: LLMResponseFormat(kind: .json)
            )
            return Self.applyLearningAidGuardrails(
                section: section,
                judge: judge,
                candidates: candidates,
                acceptedItems: judgeAcceptedItems(for: acceptedContext)
            )
        } catch {
            return Self.deterministicLearningAidFallback(
                section: section,
                candidates: candidates
            )
        }
    }

    private func rankLearningAidSectionsCombined(
        word: String,
        senses: [LLMSensePromptInput],
        aids: LLMLearningAids,
        acceptedContext: LLMLearningAidAcceptedContext
    ) async -> LLMLearningAidSelections {
        let pitfallCandidates = learningAidCandidates(for: .pitfalls, aids: aids)
        let mnemonicCandidates = learningAidCandidates(for: .mnemonics, aids: aids)
        let collocationCandidates = learningAidCandidates(for: .collocations, aids: aids)
        let acceptedItems = judgeAcceptedItems(for: acceptedContext)

        let hasAnyCandidates = !pitfallCandidates.isEmpty || !mnemonicCandidates.isEmpty || !collocationCandidates.isEmpty
        guard hasAnyCandidates else {
            return LLMLearningAidSelections()
        }

        do {
            let candidatesBySection: [String: [LearningAidJudgeCandidate]] = [
                LLMLearningAidSection.pitfalls.rawValue: pitfallCandidates,
                LLMLearningAidSection.mnemonics.rawValue: mnemonicCandidates,
                LLMLearningAidSection.collocations.rawValue: collocationCandidates
            ]
            let prompt = LLMPrompt.learningAidCombinedJudge(
                word: word,
                senses: senses,
                candidatesBySectionJSON: compactJSONString(candidatesBySection),
                acceptedJSON: compactJSONString(acceptedItems)
            )
            let judge: LearningAidCombinedJudgeEnvelope = try await generateStructuredOutput(
                type: LearningAidCombinedJudgeEnvelope.self,
                prompt: prompt,
                maxTokens: Self.learningAidCombinedJudgeMaxTokens,
                temperature: adjustedTemperature(0.2),
                responseFormat: LLMResponseFormat(kind: .json)
            )

            return LLMLearningAidSelections(
                pitfalls: selectionFromCombinedJudge(
                    section: .pitfalls,
                    judge: judge.pitfalls,
                    candidates: pitfallCandidates,
                    acceptedItems: acceptedItems
                ),
                mnemonics: selectionFromCombinedJudge(
                    section: .mnemonics,
                    judge: judge.mnemonics,
                    candidates: mnemonicCandidates,
                    acceptedItems: acceptedItems
                ),
                collocations: selectionFromCombinedJudge(
                    section: .collocations,
                    judge: judge.collocations,
                    candidates: collocationCandidates,
                    acceptedItems: acceptedItems
                )
            )
        } catch {
            return LLMLearningAidSelections(
                pitfalls: Self.deterministicLearningAidFallback(section: .pitfalls, candidates: pitfallCandidates),
                mnemonics: Self.deterministicLearningAidFallback(section: .mnemonics, candidates: mnemonicCandidates),
                collocations: Self.deterministicLearningAidFallback(section: .collocations, candidates: collocationCandidates)
            )
        }
    }

    private func learningAidCandidates(
        for section: LLMLearningAidSection,
        aids: LLMLearningAids
    ) -> [LearningAidJudgeCandidate] {
        switch section {
        case .pitfalls:
            return aids.pitfalls.map {
                LearningAidJudgeCandidate(
                    id: $0.id,
                    text: $0.summary,
                    translation: $0.translation ?? $0.details,
                    type: $0.category,
                    focus: $0.focus,
                    recallRelevant: $0.recallRelevant,
                    senseIndex: $0.senseIndex
                )
            }
        case .mnemonics:
            return aids.mnemonics.map {
                LearningAidJudgeCandidate(
                    id: $0.id,
                    text: $0.clue,
                    translation: $0.translation,
                    type: $0.kind,
                    focus: $0.focus,
                    recallRelevant: $0.recallRelevant,
                    senseIndex: $0.senseIndex
                )
            }
        case .collocations:
            return aids.collocations.map {
                LearningAidJudgeCandidate(
                    id: $0.id,
                    text: $0.phrase,
                    translation: $0.gloss,
                    type: "collocation",
                    focus: $0.focus,
                    recallRelevant: $0.recallRelevant,
                    senseIndex: $0.senseIndex
                )
            }
        }
    }

    private func judgeAcceptedItems(
        for acceptedContext: LLMLearningAidAcceptedContext
    ) -> [LearningAidJudgeAcceptedItem] {
        var items: [LearningAidJudgeAcceptedItem] = []

        func append(sectionName: String, texts: [String], recallRelevant: Bool? = nil) {
            for (index, text) in texts.enumerated() {
                let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                items.append(
                    LearningAidJudgeAcceptedItem(
                        id: "\(sectionName)-accepted-\(index)",
                        section: sectionName,
                        text: normalized,
                        focus: nil,
                        recallRelevant: recallRelevant
                    )
                )
            }
        }

        append(sectionName: "pitfalls", texts: acceptedContext.acceptedPitfalls, recallRelevant: true)
        append(sectionName: "usage", texts: acceptedContext.acceptedUsageHints)
        append(sectionName: "mnemonics", texts: acceptedContext.acceptedMnemonics)
        append(sectionName: "collocations", texts: acceptedContext.acceptedCollocations)
        return items
    }

    static func normalizeLearningAidAcceptedContext(
        _ context: LLMLearningAidAcceptedContext
    ) -> LLMLearningAidAcceptedContext {
        LLMLearningAidAcceptedContext(
            acceptedPitfalls: normalizeRecallTextItems(context.acceptedPitfalls, limit: 4),
            acceptedUsageHints: normalizeRecallTextItems(context.acceptedUsageHints, limit: 4),
            acceptedMnemonics: normalizeRecallTextItems(context.acceptedMnemonics, limit: 3),
            acceptedCollocations: normalizeRecallTextItems(context.acceptedCollocations, limit: 4)
        )
    }

    private static func applyLearningAidGuardrails(
        section: LLMLearningAidSection,
        judge: LearningAidJudgeEnvelope,
        candidates: [LearningAidJudgeCandidate],
        acceptedItems: [LearningAidJudgeAcceptedItem]
    ) -> LLMLearningAidSectionSelection {
        let candidateByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let overlapHints = judge.overlapHints.compactMap { hint -> LLMLearningAidOverlapHint? in
            guard candidateByID[hint.candidateId] != nil else { return nil }
            let reason = hint.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reason.isEmpty else { return nil }
            return LLMLearningAidOverlapHint(
                candidateID: hint.candidateId,
                overlapType: hint.overlapType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                withItemID: hint.withItemId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                reason: reason
            )
        }

        var recommendedID = judge.recommendedId.flatMap { candidateByID[$0] != nil ? $0 : nil }
        if let currentRecommendedID = recommendedID,
           let candidate = candidateByID[currentRecommendedID],
           shouldRejectRecommendedCandidate(section: section, candidate: candidate, acceptedItems: acceptedItems, overlapHints: overlapHints) {
            recommendedID = nil
        }

        if recommendedID == nil {
            recommendedID = firstValidCandidateWithoutAcceptedOverlap(
                section: section,
                candidates: candidates,
                acceptedItems: acceptedItems,
                overlapHints: overlapHints
            )?.id
        }

        guard let recommendedID else {
            return deterministicLearningAidFallback(section: section, candidates: candidates)
                ?? LLMLearningAidSectionSelection(
                    recommendedID: nil,
                    alternativeIDs: candidates.map(\.id),
                    overlapHints: overlapHints,
                    whyRecommended: nil,
                    selectionSource: "deterministic_fallback"
                )
        }

        return LLMLearningAidSectionSelection(
            recommendedID: recommendedID,
            alternativeIDs: candidates.map(\.id).filter { $0 != recommendedID },
            overlapHints: overlapHints,
            whyRecommended: judge.whyRecommended?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            selectionSource: "judge_with_guardrails"
        )
    }

    private func selectionFromCombinedJudge(
        section: LLMLearningAidSection,
        judge: LearningAidJudgeEnvelope?,
        candidates: [LearningAidJudgeCandidate],
        acceptedItems: [LearningAidJudgeAcceptedItem]
    ) -> LLMLearningAidSectionSelection? {
        guard !candidates.isEmpty else { return nil }
        guard let judge else {
            return Self.deterministicLearningAidFallback(section: section, candidates: candidates)
        }

        let selection = Self.applyLearningAidGuardrails(
            section: section,
            judge: judge,
            candidates: candidates,
            acceptedItems: acceptedItems
        )

        if selection.selectionSource == "judge_with_guardrails" {
            return LLMLearningAidSectionSelection(
                recommendedID: selection.recommendedID,
                alternativeIDs: selection.alternativeIDs,
                overlapHints: selection.overlapHints,
                whyRecommended: selection.whyRecommended,
                selectionSource: "combined_judge_with_guardrails"
            )
        }

        return selection
    }

    private static func deterministicLearningAidFallback(
        section: LLMLearningAidSection,
        candidates: [LearningAidJudgeCandidate]
    ) -> LLMLearningAidSectionSelection? {
        let valid = candidates.filter { isValidLearningAidCandidate($0, for: section) }
        guard !valid.isEmpty else { return nil }
        let sorted = valid.sorted {
            fallbackPriority(for: $0, section: section) > fallbackPriority(for: $1, section: section)
        }
        guard let recommended = sorted.first else { return nil }
        return LLMLearningAidSectionSelection(
            recommendedID: recommended.id,
            alternativeIDs: sorted.dropFirst().map(\.id),
            overlapHints: [],
            whyRecommended: nil,
            selectionSource: "deterministic_fallback"
        )
    }

    private static func reorderLearningAids(
        _ aids: LLMLearningAids,
        selections: LLMLearningAidSelections
    ) -> LLMLearningAids {
        LLMLearningAids(
            pitfalls: reorder(aids.pitfalls, selection: selections.pitfalls),
            mnemonics: reorder(aids.mnemonics, selection: selections.mnemonics),
            collocations: reorder(aids.collocations, selection: selections.collocations)
        )
    }

    private static func reorder(_ items: [LLMPitfall], selection: LLMLearningAidSectionSelection?) -> [LLMPitfall] {
        guard let selection else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return orderedIDs(selection: selection, allIDs: items.map(\.id)).compactMap { byID[$0] }
    }

    private static func reorder(_ items: [LLMMnemonic], selection: LLMLearningAidSectionSelection?) -> [LLMMnemonic] {
        guard let selection else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return orderedIDs(selection: selection, allIDs: items.map(\.id)).compactMap { byID[$0] }
    }

    private static func reorder(_ items: [LLMCollocation], selection: LLMLearningAidSectionSelection?) -> [LLMCollocation] {
        guard let selection else { return items }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        return orderedIDs(selection: selection, allIDs: items.map(\.id)).compactMap { byID[$0] }
    }

    private static func orderedIDs(selection: LLMLearningAidSectionSelection, allIDs: [String]) -> [String] {
        var ordered: [String] = []
        if let recommendedID = selection.recommendedID {
            ordered.append(recommendedID)
        }
        ordered.append(contentsOf: selection.alternativeIDs.filter { !ordered.contains($0) })
        ordered.append(contentsOf: allIDs.filter { !ordered.contains($0) })
        return ordered
    }

    private static func shouldRejectRecommendedCandidate(
        section: LLMLearningAidSection,
        candidate: LearningAidJudgeCandidate,
        acceptedItems: [LearningAidJudgeAcceptedItem],
        overlapHints: [LLMLearningAidOverlapHint]
    ) -> Bool {
        !isValidLearningAidCandidate(candidate, for: section) ||
            overlapHints.contains(where: { $0.candidateID == candidate.id && $0.overlapType == "accepted_overlap" }) ||
            acceptedItems.contains(where: { normalizedLearningAidText($0.text) == normalizedLearningAidText(candidate.text) })
    }

    private static func firstValidCandidateWithoutAcceptedOverlap(
        section: LLMLearningAidSection,
        candidates: [LearningAidJudgeCandidate],
        acceptedItems: [LearningAidJudgeAcceptedItem],
        overlapHints: [LLMLearningAidOverlapHint]
    ) -> LearningAidJudgeCandidate? {
        candidates.first { candidate in
            guard isValidLearningAidCandidate(candidate, for: section) else { return false }
            let hasAcceptedOverlap = overlapHints.contains {
                $0.candidateID == candidate.id && $0.overlapType == "accepted_overlap"
            }
            let exactDuplicate = acceptedItems.contains {
                normalizedLearningAidText($0.text) == normalizedLearningAidText(candidate.text)
            }
            return !hasAcceptedOverlap && !exactDuplicate
        }
    }

    private static func isValidLearningAidCandidate(
        _ candidate: LearningAidJudgeCandidate,
        for section: LLMLearningAidSection
    ) -> Bool {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !isGenericLearningAidText(text) else { return false }

        switch section {
        case .pitfalls:
            return text.split(whereSeparator: \.isWhitespace).count <= 20 &&
                candidate.type != "usage_tendency"
        case .mnemonics:
            return text.split(whereSeparator: \.isWhitespace).count <= 18
        case .collocations:
            return text.split(whereSeparator: \.isWhitespace).count <= 8
        }
    }

    private static func isGenericLearningAidText(_ text: String) -> Bool {
        let normalized = normalizedLearningAidText(text)
        let genericPatterns = [
            "this is a useful word",
            "be careful with this word",
            "this word is common",
            "useful in many contexts"
        ]
        return genericPatterns.contains { normalized.contains($0) }
    }

    private static func normalizedLearningAidText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func fallbackPriority(
        for candidate: LearningAidJudgeCandidate,
        section: LLMLearningAidSection
    ) -> Int {
        let base: Int
        switch section {
        case .pitfalls:
            switch candidate.type {
            case "spelling_trap": base = 40
            case "confusable_word": base = 30
            case "common_misuse": base = 20
            case "meaning_misdirection": base = 10
            default: base = 0
            }
        case .mnemonics:
            base = candidate.recallRelevant == true ? 20 : 10
        case .collocations:
            base = candidate.recallRelevant == true ? 15 : 10
        }

        let brevityBonus = max(0, 20 - candidate.text.split(whereSeparator: \.isWhitespace).count)
        return base + brevityBonus
    }

    private func compactJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
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

    // MARK: - OpenAI Mapping Helpers

    private static func mapResponseFormat(_ format: LLMResponseFormat) -> ChatResponseFormat? {
        switch format.kind {
        case .text:
            return ChatResponseFormat(type: "text")
        case .json:
            return ChatResponseFormat(type: "json_object")
        case .jsonSchema:
            guard let schema = format.schema else {
                return ChatResponseFormat(type: "json_object")
            }
            return ChatResponseFormat(
                type: "json_schema",
                json_schema: ChatJSONSchemaSpec(name: "response", schema: schema, strict: format.strict)
            )
        }
    }

    static func primaryResponseText(from response: ChatCompletionResponse) -> String {
        let choice = response.choices.first
        let content = choice?.message.content ?? ""
        let reasoning = choice?.message.reasoning_content ?? ""
        return (content.isEmpty ? reasoning : content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strictStructuredResponseText(
        from response: ChatCompletionResponse,
        operation: String,
        allowReasoningFallback: Bool
    ) throws -> String {
        let choice = response.choices.first
        let content = choice?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !content.isEmpty {
            return content
        }

        let reasoning = choice?.message.reasoning_content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if allowReasoningFallback, !reasoning.isEmpty {
            return reasoning
        }

        let finishReason = choice?.finish_reason ?? "unknown"
        throw LLMServiceError.invalidStructuredOutput(
            "\(operation) returned no structured content (finish_reason: \(finishReason))"
        )
    }

    static func mapToGenerateResult(_ response: ChatCompletionResponse) -> GenerateResult {
        let choice = response.choices.first
        let text = primaryResponseText(from: response)
        let finishReason = choice?.finish_reason

        let toolCalls: [LLMToolCall]? = choice?.message.tool_calls.flatMap { calls in
            let mapped = calls.compactMap { call -> LLMToolCall? in
                let name = call.function.name
                guard !name.isEmpty else { return nil }
                let arguments = decodeToolCallArguments(call.function.arguments)
                return LLMToolCall(id: call.id, name: name, arguments: arguments)
            }
            return mapped.isEmpty ? nil : mapped
        }

        let tokensUsed = response.usage?.completion_tokens ?? response.usage?.total_tokens ?? 0

        let reasoning = choice?.message.reasoning_content

        return GenerateResult(
            text: text,
            tokensUsed: tokensUsed,
            durationMs: 0,
            finishReason: finishReason,
            toolCalls: toolCalls,
            reasoning: reasoning
        )
    }

    private static func decodeToolCallArguments(_ raw: String) -> JSONValue {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return .object([:])
        }
        if let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) {
            return decoded
        }
        return .string(trimmed)
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
