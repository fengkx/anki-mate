// RPC method dispatcher — routes JSON-RPC requests to the appropriate handler.

import Foundation
import AnkiMateRPC

protocol InferenceServing: AnyObject {
    var isModelLoaded: Bool { get }
    var loadedModelPath: String? { get }

    func loadModel(path: String, contextSize: Int, gpuLayers: Int) throws
    func unloadModel()
    func generate(
        prompt: String,
        systemPrompt: String?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float
    ) throws -> GenerateResult
    func generateStreaming(
        prompt: String,
        systemPrompt: String?,
        responseFormat: LLMResponseFormat?,
        maxTokens: Int,
        temperature: Float,
        onToken: (String) -> Void
    ) throws -> GenerateResult
}

final class RPCDispatcher {
    private let engine: InferenceServing

    init(engine: InferenceServing) {
        self.engine = engine
    }

    var isModelLoaded: Bool {
        engine.isModelLoaded
    }

    func generateStreaming(
        params: GenerateParams,
        onToken: (String) -> Void
    ) throws -> GenerateResult {
        guard engine.isModelLoaded else {
            throw InferenceError.modelNotLoaded
        }
        return try engine.generateStreaming(
            prompt: params.prompt,
            systemPrompt: params.systemPrompt,
            responseFormat: params.responseFormat,
            maxTokens: params.maxTokens,
            temperature: params.temperature,
            onToken: onToken
        )
    }

    func dispatch(_ request: JSONRPCRawRequest, uptimeSeconds: Int) -> JSONRPCResponseEnvelope {
        let id = request.id

        switch request.method {
        case RPCMethod.health:
            return handleHealth(id: id, uptimeSeconds: uptimeSeconds)

        case RPCMethod.loadModel:
            return handleLoadModel(request, id: id)

        case RPCMethod.unloadModel:
            return handleUnloadModel(id: id)

        case RPCMethod.generate:
            return handleGenerate(request, id: id)

        case RPCMethod.shutdown:
            return handleShutdown(id: id)

        default:
            return .failure(
                JSONRPCError(code: -32601, message: "Method not found: \(request.method)"),
                id: id
            )
        }
    }

    // MARK: - Handlers

    private func handleHealth(id: Int?, uptimeSeconds: Int) -> JSONRPCResponseEnvelope {
        let status: ServerStatus
        let modelId: String?

        if engine.isModelLoaded {
            status = .ready
            modelId = engine.loadedModelPath
        } else {
            status = .noModel
            modelId = nil
        }

        let result = HealthResult(status: status, modelId: modelId, uptimeSeconds: uptimeSeconds)
        return .success(result, id: id ?? 0)
    }

    private func handleLoadModel(_ request: JSONRPCRawRequest, id: Int?) -> JSONRPCResponseEnvelope {
        guard let params = request.params else {
            return .failure(.invalidParams, id: id)
        }

        let loadParams: LoadModelParams
        do {
            loadParams = try params.decode(LoadModelParams.self)
        } catch {
            return .failure(
                JSONRPCError(code: -32602, message: "Invalid params: \(error.localizedDescription)"),
                id: id
            )
        }

        do {
            try engine.loadModel(
                path: loadParams.modelPath,
                contextSize: loadParams.contextSize,
                gpuLayers: loadParams.gpuLayers
            )
            return .success(LoadModelResult(), id: id ?? 0)
        } catch {
            return .failure(.modelLoadFailed(error.localizedDescription), id: id)
        }
    }

    private func handleUnloadModel(id: Int?) -> JSONRPCResponseEnvelope {
        engine.unloadModel()
        return .success(UnloadModelResult(), id: id ?? 0)
    }

    private func handleGenerate(_ request: JSONRPCRawRequest, id: Int?) -> JSONRPCResponseEnvelope {
        guard let params = request.params else {
            return .failure(.invalidParams, id: id)
        }

        let genParams: GenerateParams
        do {
            genParams = try params.decode(GenerateParams.self)
        } catch {
            return .failure(
                JSONRPCError(code: -32602, message: "Invalid params: \(error.localizedDescription)"),
                id: id
            )
        }

        guard engine.isModelLoaded else {
            return .failure(.modelNotLoaded(), id: id)
        }

        do {
            let result = try engine.generate(
                prompt: genParams.prompt,
                systemPrompt: genParams.systemPrompt,
                responseFormat: genParams.responseFormat,
                maxTokens: genParams.maxTokens,
                temperature: genParams.temperature
            )
            return .success(result, id: id ?? 0)
        } catch {
            return .failure(.inferenceError(error.localizedDescription), id: id)
        }
    }

    private func handleShutdown(id: Int?) -> JSONRPCResponseEnvelope {
        fputs("Shutdown requested via RPC\n", stderr)
        return .success(ShutdownResult(), id: id ?? 0)
    }
}
