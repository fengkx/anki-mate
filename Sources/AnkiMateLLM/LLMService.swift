// LLMService — main public API for LLM features in the app.
// Manages the server lifecycle, model loading, and provides high-level generation methods.

import Foundation
import Combine
import AnkiMateRPC

@MainActor
public final class LLMService: ObservableObject {
    private static let selectedModelIdDefaultsKey = "ankimate.selectedModelId"
    private static let lastSuccessfulModelIdDefaultsKey = "ankimate.lastSuccessfullyLoadedModelId"
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

    public init(defaults: UserDefaults = .standard) {
        let client = RPCClient()
        self.rpcClient = client
        self.defaults = defaults
        self.registry = ModelRegistry()
        self.downloadManager = ModelDownloadManager()
        self.serverManager = ServerProcessManager(rpcClient: client)
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
                    contextSize: model.contextSize,
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

        await startServer()
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
            temperature: 0.45
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
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.optimizeDefinition(
            word: word,
            senses: senses
        )
        let hintCount = LLMPrompt.usageHintCount(for: senses)

        let result: GenerateResult = try await rpcClient.call(
            method: RPCMethod.generate,
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: max(220, hintCount * 88),
                temperature: 0.5
            ),
            port: port
        )

        return normalizeUsageHint(result.text)
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

        let prompt = LLMPrompt.optimizeDefinition(
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
        return normalizeUsageHint(result.text)
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
        let requestedModes = modes.isEmpty ? LLMRecallCardMode.allCases : modes
        let prompt = LLMPrompt.recallCardDrafts(
            word: word,
            senses: senses,
            modes: requestedModes,
            anchor: anchor
        )

        let response: RecallCardDraftEnvelope = try await generateStructuredOutput(
            type: RecallCardDraftEnvelope.self,
            prompt: prompt,
            maxTokens: max(420, requestedModes.count * 140),
            temperature: 0.35
        )

        return Self.normalizeRecallCardDrafts(
            response.drafts,
            requestedModes: requestedModes
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
            temperature: 0.4
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
            .map { normalizeGeneratedLine(String($0)) }
            .filter { !$0.isEmpty }
    }

    private func normalizeExampleSentences(
        _ examples: [LLMExampleSentence],
        senseCount: Int,
        desiredCount: Int
    ) -> [LLMExampleSentence] {
        examples.compactMap { example in
            let english = normalizeGeneratedLine(example.english)
            let translation = normalizeGeneratedLine(example.translation)
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

    private func normalizeUsageHint(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { normalizeGeneratedLine(String($0), convertBilingualLabels: true) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func normalizeGeneratedLine(
        _ text: String,
        convertBilingualLabels: Bool = false
    ) -> String {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = normalized.range(
            of: #"^(?:[-*•]\s+|\d+\s*[\.\)\:\-–—]\s+)"#,
            options: .regularExpression
        ) {
            normalized = String(normalized[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard convertBilingualLabels else {
            return normalized
        }

        let candidate = normalized
        let pattern = #"^(?:[A-Za-z][A-Za-z /-]*\s+)?EN:\s*(.+?)\s*\|\s*ZH:\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return normalized
        }

        let nsRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        guard let result = regex.firstMatch(in: candidate, range: nsRange),
              let enRange = Range(result.range(at: 1), in: candidate),
              let zhRange = Range(result.range(at: 2), in: candidate) else {
            return normalized
        }

        return "\(candidate[enRange]) — \(candidate[zhRange])"
    }

    private func generateStructuredOutput<T: Decodable>(
        type: T.Type,
        prompt: (system: String, user: String),
        maxTokens: Int,
        temperature: Float
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
}

struct RecallCardDraftEnvelope: Decodable {
    let drafts: [RecallCardDraftPayload]

    private enum CodingKeys: String, CodingKey {
        case drafts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.drafts = try container.decodeIfPresent([RecallCardDraftPayload].self, forKey: .drafts) ?? []
    }
}

struct ExampleSentenceEnvelope: Decodable {
    let examples: [LLMExampleSentence]

    private enum CodingKeys: String, CodingKey {
        case examples
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.examples = try container.decodeIfPresent([LLMExampleSentence].self, forKey: .examples) ?? []
    }
}

struct RecallCardDraftPayload: Decodable {
    let mode: String
    let front: String
    let back: String
    let hint: String?
    let anchor: LLMAnchorSnapshot?
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
        requestedModes: [LLMRecallCardMode]
    ) -> [LLMRecallCardDraft] {
        let requestedModeSet = Set(requestedModes)
        var draftsByMode: [LLMRecallCardMode: LLMRecallCardDraft] = [:]

        for payload in payloads {
            guard let mode = normalizedRecallCardMode(from: payload.mode),
                  requestedModeSet.contains(mode),
                  draftsByMode[mode] == nil,
                  let draft = normalizeRecallCardDraft(payload, mode: mode) else {
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
        mode: LLMRecallCardMode
    ) -> LLMRecallCardDraft? {
        let front = payload.front.trimmingCharacters(in: .whitespacesAndNewlines)
        let back = payload.back.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !front.isEmpty, !back.isEmpty else { return nil }

        let hint = payload.hint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let anchor = normalizeAnchor(payload.anchor)
        return LLMRecallCardDraft(
            mode: mode,
            front: front,
            back: back,
            hint: hint,
            anchor: anchor
        )
    }

    private static func normalizePitfall(_ payload: PitfallPayload) -> LLMPitfall? {
        let summary = payload.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { return nil }
        return LLMPitfall(
            summary: summary,
            details: payload.details?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            anchor: normalizeAnchor(payload.anchor)
        )
    }

    private static func normalizeMnemonic(_ payload: MnemonicPayload) -> LLMMnemonic? {
        let clue = payload.clue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clue.isEmpty else { return nil }
        return LLMMnemonic(
            clue: clue,
            anchor: normalizeAnchor(payload.anchor)
        )
    }

    private static func normalizeCollocation(_ payload: CollocationPayload) -> LLMCollocation? {
        let phrase = payload.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return nil }
        return LLMCollocation(
            phrase: phrase,
            gloss: payload.gloss?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
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
