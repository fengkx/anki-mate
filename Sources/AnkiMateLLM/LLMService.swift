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

    // MARK: - High-Level Generation

    /// Generate example sentences for a word.
    public func generateExampleSentences(
        word: String,
        definition: String,
        partOfSpeech: String
    ) async throws -> [String] {
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.exampleSentences(
            word: word,
            partOfSpeech: partOfSpeech,
            definition: definition
        )

        let result: GenerateResult = try await rpcClient.call(
            method: RPCMethod.generate,
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: 300,
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
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.exampleSentences(
            word: word,
            partOfSpeech: partOfSpeech,
            definition: definition
        )

        let result = try await rpcClient.streamGenerate(
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: 360,
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
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.optimizeDefinition(
            word: word,
            rawDefinition: rawDefinition
        )

        let result: GenerateResult = try await rpcClient.call(
            method: RPCMethod.generate,
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: 200,
                temperature: 0.5
            ),
            port: port
        )

        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func optimizeDefinitionStreaming(
        word: String,
        rawDefinition: String,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        try await ensureReady()
        guard let port = serverState.port else {
            throw LLMServiceError.serverNotAvailable
        }

        let prompt = LLMPrompt.optimizeDefinition(
            word: word,
            rawDefinition: rawDefinition
        )

        let result = try await rpcClient.streamGenerate(
            params: GenerateParams(
                prompt: prompt.user,
                systemPrompt: prompt.system,
                maxTokens: 240,
                temperature: 0.5
            ),
            port: port,
            onDelta: onDelta
        )
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func parseSentences(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { line -> String in
                var s = String(line).trimmingCharacters(in: .whitespaces)
                // Strip leading number + dot/parenthesis: "1. ...", "1) ...", "1: ..."
                if let range = s.range(of: #"^\d+[\.\)\:\-]\s*"#, options: .regularExpression) {
                    s = String(s[range.upperBound...])
                }
                return s
            }
            .filter { !$0.isEmpty }
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
