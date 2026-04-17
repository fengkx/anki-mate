// RPC method dispatcher — routes JSON-RPC requests to the appropriate handler.

import Foundation
import AnkiMateRPC

final class RPCDispatcher {
    private let engine: InferenceEngine

    init(engine: InferenceEngine) {
        self.engine = engine
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
