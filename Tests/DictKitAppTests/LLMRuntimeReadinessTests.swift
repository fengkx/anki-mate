import Foundation
import XCTest
import AnkiMateRPC
@testable import AnkiMateLLM

@MainActor
final class LLMRuntimeReadinessTests: XCTestCase {
    private let selectedModelDefaultsKey = "ankimate.selectedModelId"
    private let lastSuccessfulModelDefaultsKey = "ankimate.lastSuccessfullyLoadedModelId"

    func testAutoActivationSkipsStartupWhenNoDownloadedModelExists() async {
        let context = makeContext()
        let models = [
            makeModel(id: "runtime-alpha"),
            makeModel(id: "runtime-beta")
        ]
        let service = makeService(
            context: context,
            models: models,
            selectedModelId: models[0].id
        )

        service.enableAutoStartOnAvailableModel()
        await service.autoActivateInferenceServerIfPossible()

        XCTAssertEqual(service.serverState, ServerProcessManager.State.stopped)
        XCTAssertNil(service.loadedModelId)
        XCTAssertEqual(service.selectedModelId, models[0].id)
        XCTAssertFalse(service.hasModel)
    }

    func testAutoActivationKeepsCurrentDownloadedSelectionEvenWhenAnotherModelWasLastSuccessful() async throws {
        let context = makeContext()
        let models = [
            makeModel(id: "runtime-alpha"),
            makeModel(id: "runtime-beta")
        ]
        let service = makeService(
            context: context,
            models: models,
            selectedModelId: models[0].id,
            lastSuccessfulModelId: models[1].id
        )
        try materializeDownloadedModel(models[0], with: service.downloadManager)
        try materializeDownloadedModel(models[1], with: service.downloadManager)

        service.enableAutoStartOnAvailableModel()
        await service.autoActivateInferenceServerIfPossible()

        XCTAssertEqual(service.selectedModelId, models[0].id)
        XCTAssertTrue(service.hasModel)
        XCTAssertNil(service.loadedModelId)
        XCTAssertFalse(service.isReady)
        XCTAssertNotEqual(service.serverState, ServerProcessManager.State.stopped)
    }

    func testAutoActivationUsesLastSuccessfulModelWhenCurrentSelectionIsMissing() async throws {
        let context = makeContext()
        let models = [
            makeModel(id: "runtime-alpha"),
            makeModel(id: "runtime-beta")
        ]
        let service = makeService(
            context: context,
            models: models,
            selectedModelId: "missing",
            lastSuccessfulModelId: models[1].id
        )
        try materializeDownloadedModel(models[1], with: service.downloadManager)

        service.enableAutoStartOnAvailableModel()
        await service.autoActivateInferenceServerIfPossible()

        XCTAssertEqual(service.selectedModelId, models[1].id)
        XCTAssertTrue(service.hasModel)
        XCTAssertNil(service.loadedModelId)
        XCTAssertFalse(service.isReady)
        XCTAssertNotEqual(service.serverState, ServerProcessManager.State.stopped)
    }

    func testFirstRequestAttemptsLazyReadinessWithoutManualStartup() async {
        let context = makeContext()
        let models = [
            makeModel(id: "runtime-alpha")
        ]
        let service = makeService(
            context: context,
            models: models,
            selectedModelId: models[0].id
        )

        XCTAssertEqual(service.serverState, ServerProcessManager.State.stopped)

        do {
            _ = try await service.generateExampleSentenceArtifacts(
                word: "light",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "illumination")
                ]
            )
            XCTFail("Expected the first request to fail cleanly without a real downloaded model.")
        } catch {
            assertGracefulReadinessError(error)
        }

        XCTAssertNotEqual(service.serverState, ServerProcessManager.State.stopped)
        XCTAssertNil(service.loadedModelId)
        XCTAssertFalse(service.isReady)
    }

    func testWarmupCoordinatorRunsWarmupOnlyOncePerLoadedModel() async throws {
        let coordinator = LLMWarmupCoordinator()
        let recorder = WarmupRecorder()
        let rpcClient = RPCClient()

        try await coordinator.warmIfNeeded(
            modelId: "runtime-alpha",
            modelPath: "/tmp/runtime-alpha.gguf",
            inferencePort: 8081,
            rpcClient: rpcClient
        ) { _, port, modelPath in
            await recorder.record(port: port, modelPath: modelPath)
        }

        try await coordinator.warmIfNeeded(
            modelId: "runtime-alpha",
            modelPath: "/tmp/runtime-alpha.gguf",
            inferencePort: 8081,
            rpcClient: rpcClient
        ) { _, port, modelPath in
            await recorder.record(port: port, modelPath: modelPath)
        }

        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.count, 1)
        XCTAssertEqual(invocations.first?.port, 8081)
        XCTAssertEqual(invocations.first?.modelPath, "/tmp/runtime-alpha.gguf")
    }

    func testWarmupCoordinatorAllowsWarmupAgainAfterReset() async throws {
        let coordinator = LLMWarmupCoordinator()
        let recorder = WarmupRecorder()
        let rpcClient = RPCClient()

        try await coordinator.warmIfNeeded(
            modelId: "runtime-alpha",
            modelPath: "/tmp/runtime-alpha.gguf",
            inferencePort: 8081,
            rpcClient: rpcClient
        ) { _, port, modelPath in
            await recorder.record(port: port, modelPath: modelPath)
        }

        await coordinator.reset()

        try await coordinator.warmIfNeeded(
            modelId: "runtime-alpha",
            modelPath: "/tmp/runtime-alpha.gguf",
            inferencePort: 8081,
            rpcClient: rpcClient
        ) { _, port, modelPath in
            await recorder.record(port: port, modelPath: modelPath)
        }

        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.count, 2)
    }

    func testWarmupCoordinatorRunsAgainWhenModelPathChanges() async throws {
        let coordinator = LLMWarmupCoordinator()
        let recorder = WarmupRecorder()
        let rpcClient = RPCClient()

        try await coordinator.warmIfNeeded(
            modelId: "runtime-alpha",
            modelPath: "/tmp/runtime-alpha-v1.gguf",
            inferencePort: 8081,
            rpcClient: rpcClient
        ) { _, port, modelPath in
            await recorder.record(port: port, modelPath: modelPath)
        }

        try await coordinator.warmIfNeeded(
            modelId: "runtime-alpha",
            modelPath: "/tmp/runtime-alpha-v2.gguf",
            inferencePort: 8081,
            rpcClient: rpcClient
        ) { _, port, modelPath in
            await recorder.record(port: port, modelPath: modelPath)
        }

        let invocations = await recorder.invocations
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(
            invocations.map(\.modelPath),
            ["/tmp/runtime-alpha-v1.gguf", "/tmp/runtime-alpha-v2.gguf"]
        )
    }

    func testInferenceRequestGateSkipsWarmupWhileForegroundLeaseIsActive() async throws {
        let gate = LLMInferenceRequestGate()
        let foregroundLease = try await gate.acquireForegroundLease()

        let warmupLease = await gate.tryAcquireWarmupLease()

        XCTAssertNil(warmupLease)
        await gate.release(foregroundLease)
    }

    func testInferenceRequestGateSkipsWarmupWhileForegroundRequestIsWaiting() async throws {
        let gate = LLMInferenceRequestGate()
        let activeLease = try await gate.acquireForegroundLease()

        let foregroundTask = Task {
            try await gate.acquireForegroundLease()
        }
        defer { foregroundTask.cancel() }

        await Task.yield()
        let warmupLease = await gate.tryAcquireWarmupLease()

        XCTAssertNil(warmupLease)

        await gate.release(activeLease)
        let queuedLease = try await foregroundTask.value
        await gate.release(queuedLease)
    }
}

private extension LLMRuntimeReadinessTests {
    actor WarmupRecorder {
        struct Invocation: Equatable {
            let port: Int
            let modelPath: String
        }

        private(set) var invocations: [Invocation] = []

        func record(port: Int, modelPath: String) {
            invocations.append(Invocation(port: port, modelPath: modelPath))
        }
    }

    struct TestContext {
        let defaults: UserDefaults
        let baseDirectoryURL: URL
    }

    func makeContext() -> TestContext {
        let suiteName = "LLMRuntimeReadinessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let baseDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)

        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: baseDirectoryURL)
        }

        return TestContext(defaults: defaults, baseDirectoryURL: baseDirectoryURL)
    }

    func makeModel(id: String) -> ModelInfo {
        ModelInfo(
            id: id,
            displayName: id,
            fileName: "\(id)-\(UUID().uuidString).gguf",
            url: "https://example.com/\(id).gguf",
            sizeBytes: 1_024,
            quantization: "Q4_K_M",
            contextSize: 4_096
        )
    }

    func makeService(
        context: TestContext,
        models: [ModelInfo],
        selectedModelId: String,
        lastSuccessfulModelId: String? = nil,
        warmupRequest: @escaping LLMWarmupRequest = LLMWarmupCoordinator.defaultWarmupRequest
    ) -> LLMService {
        context.defaults.set(selectedModelId, forKey: selectedModelDefaultsKey)
        if let lastSuccessfulModelId {
            context.defaults.set(lastSuccessfulModelId, forKey: lastSuccessfulModelDefaultsKey)
        }

        let rpcClient = RPCClient()
        return LLMService(
            defaults: context.defaults,
            registry: ModelRegistry(models: models),
            downloadManager: ModelDownloadManager(baseDirectoryURL: context.baseDirectoryURL),
            serverManager: ServerProcessManager(rpcClient: rpcClient),
            rpcClient: rpcClient,
            warmupRequest: warmupRequest
        )
    }

    func materializeDownloadedModel(_ model: ModelInfo, with manager: ModelDownloadManager) throws {
        let fileURL = manager.localPath(for: model)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub".utf8).write(to: fileURL)
    }

    func assertGracefulReadinessError(_ error: Error) {
        if let serviceError = error as? LLMServiceError {
            switch serviceError {
            case .serverNotAvailable, .modelNotDownloaded:
                return
            default:
                break
            }
        }

        if let rpcError = error as? RPCClientError {
            switch rpcError {
            case .rpcError, .serverNotRunning, .httpError, .upstreamError:
                return
            case .decodingError:
                break
            }
        }

        XCTFail("Unexpected readiness error: \(error)")
    }
}
