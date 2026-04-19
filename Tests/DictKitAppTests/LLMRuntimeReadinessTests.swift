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
}

private extension LLMRuntimeReadinessTests {
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
        lastSuccessfulModelId: String? = nil
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
            rpcClient: rpcClient
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
            case .rpcError, .serverNotRunning, .httpError:
                return
            case .decodingError:
                break
            }
        }

        XCTFail("Unexpected readiness error: \(error)")
    }
}
