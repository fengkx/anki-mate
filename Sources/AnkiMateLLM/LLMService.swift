// LLMService — main public API for LLM features in the app.
// Manages the server lifecycle, model loading, and provides high-level generation methods.

import Foundation
import Combine
import AnkiMateRPC

@MainActor
public final class LLMService: ObservableObject {

    @Published public private(set) var serverState: ServerProcessManager.State = .stopped
    @Published public private(set) var loadedModelId: String?
    @Published public var selectedModelId: String {
        didSet {
            UserDefaults.standard.set(selectedModelId, forKey: "ankimate.selectedModelId")
        }
    }

    public let registry: ModelRegistry
    public let downloadManager: ModelDownloadManager
    public let serverManager: ServerProcessManager

    private let rpcClient: RPCClient
    private var cancellables = Set<AnyCancellable>()
    private var autoStartOnAvailableModel = false
    private var autoStartTask: Task<Void, Never>?

    public init() {
        let client = RPCClient()
        self.rpcClient = client
        self.registry = ModelRegistry()
        self.downloadManager = ModelDownloadManager()
        self.serverManager = ServerProcessManager(rpcClient: client)
        self.selectedModelId = UserDefaults.standard.string(forKey: "ankimate.selectedModelId") ?? ""

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
                params: LoadModelParams(modelPath: modelPath, contextSize: model.contextSize),
                port: port
            )

            loadedModelId = model.id
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

    // MARK: - Helpers

    private func parseSentences(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { normalizeGeneratedLine(String($0)) }
            .filter { !$0.isEmpty }
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
        currentSelectedModelId: String,
        registryModels: [ModelInfo],
        downloadedModelIDs: Set<String>
    ) -> String? {
        guard !downloadedModelIDs.isEmpty else { return nil }
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
}

// MARK: - Errors

public enum LLMServiceError: Error, LocalizedError {
    case serverNotAvailable
    case noModelSelected
    case modelNotDownloaded

    public var errorDescription: String? {
        switch self {
        case .serverNotAvailable: return "Inference server is not available"
        case .noModelSelected: return "No model selected"
        case .modelNotDownloaded: return "Selected model has not been downloaded yet"
        }
    }
}
