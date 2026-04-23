// RPC method dispatcher — routes JSON-RPC requests to the appropriate handler.
//
// Control plane only: health, loadModel, unloadModel, shutdown.
// Data plane requests go directly to the llama-server child port discovered via health.

import Foundation
import AnkiMateRPC

final class RPCDispatcher {
    private let supervisor: LlamaServerSupervising

    init(supervisor: LlamaServerSupervising) {
        self.supervisor = supervisor
    }

    func dispatch(_ request: JSONRPCRawRequest, uptimeSeconds: Int) async -> JSONRPCResponseEnvelope {
        let id = request.id

        switch request.method {
        case RPCMethod.health:
            return handleHealth(id: id, uptimeSeconds: uptimeSeconds)

        case RPCMethod.loadModel:
            return await handleLoadModel(request, id: id)

        case RPCMethod.unloadModel:
            return await handleUnloadModel(id: id)

        case RPCMethod.shutdown:
            return await handleShutdown(id: id)

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
        let inferencePort: Int?

        switch supervisor.state {
        case .ready(let port, let path):
            status = .ready
            modelId = path
            inferencePort = port
        case .starting:
            status = .loadingModel
            modelId = nil
            inferencePort = nil
        default:
            status = .noModel
            modelId = nil
            inferencePort = nil
        }

        let result = HealthResult(status: status, modelId: modelId, uptimeSeconds: uptimeSeconds, inferencePort: inferencePort)
        return .success(result, id: id ?? 0)
    }

    private func handleLoadModel(_ request: JSONRPCRawRequest, id: Int?) async -> JSONRPCResponseEnvelope {
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
            try await supervisor.loadModel(
                path: loadParams.modelPath,
                mmprojPath: loadParams.mmprojPath,
                contextSize: loadParams.contextSize,
                gpuLayers: loadParams.gpuLayers
            )
            return .success(LoadModelResult(), id: id ?? 0)
        } catch {
            return .failure(.modelLoadFailed(error.localizedDescription), id: id)
        }
    }

    private func handleUnloadModel(id: Int?) async -> JSONRPCResponseEnvelope {
        await supervisor.unloadModel()
        return .success(UnloadModelResult(), id: id ?? 0)
    }

    private func handleShutdown(id: Int?) async -> JSONRPCResponseEnvelope {
        fputs("Shutdown requested via RPC\n", stderr)
        await supervisor.shutdown()
        return .success(ShutdownResult(), id: id ?? 0)
    }
}
