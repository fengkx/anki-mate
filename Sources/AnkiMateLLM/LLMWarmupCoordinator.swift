import Foundation
import AnkiMateRPC

typealias LLMWarmupRequest = @Sendable (RPCClient, Int, String) async throws -> Void

actor LLMWarmupCoordinator {
    private struct WarmedModelKey: Equatable {
        let modelId: String
        let modelPath: String
    }

    private var warmedModelKey: WarmedModelKey?

    func warmIfNeeded(
        modelId: String,
        modelPath: String,
        inferencePort: Int,
        rpcClient: RPCClient,
        warmupRequest: @escaping LLMWarmupRequest
    ) async throws {
        let warmedModelKey = WarmedModelKey(modelId: modelId, modelPath: modelPath)
        guard self.warmedModelKey != warmedModelKey else { return }

        try Task.checkCancellation()
        try await warmupRequest(rpcClient, inferencePort, modelPath)
        try Task.checkCancellation()

        self.warmedModelKey = warmedModelKey
    }

    func reset() {
        warmedModelKey = nil
    }

    static let defaultWarmupRequest: LLMWarmupRequest = { rpcClient, inferencePort, modelPath in
        _ = try await rpcClient.chatCompletion(
            request: ChatCompletionRequest(
                model: modelPath,
                messages: [
                    ChatMessage(role: "system", content: "You are performing startup warmup. Reply with OK."),
                    ChatMessage(role: "user", content: "OK")
                ],
                temperature: 0,
                max_completion_tokens: 4
            ),
            port: inferencePort
        )
    }
}
