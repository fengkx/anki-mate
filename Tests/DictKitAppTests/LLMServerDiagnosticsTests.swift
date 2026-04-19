import Foundation
import XCTest
import AnkiMateRPC
@testable import DictKitApp
@testable import AnkiMateLLM

@MainActor
final class LLMServerDiagnosticsTests: XCTestCase {
    private let selectedModelDefaultsKey = "ankimate.selectedModelId"

    func testReportIncludesFailureAndBinaryPresence() async throws {
        let context = makeContext()
        let model = makeModel(id: "diagnostics-alpha")
        let service = makeService(context: context, models: [model], selectedModelId: model.id)
        await service.startServer()

        let report = LLMServerDiagnostics.makeReport(service: service)

        XCTAssertTrue(report.contains("Anki Mate Local AI Diagnostics"))
        XCTAssertTrue(report.contains("Server state: failed (Server binary not found)"))
        XCTAssertTrue(report.contains("Selected model: \(model.id)"))
        XCTAssertTrue(report.contains("Development server binary: .build/debug/AnkiMateServer [missing]"))
    }

}

private extension LLMServerDiagnosticsTests {
    struct TestContext {
        let defaults: UserDefaults
        let baseDirectoryURL: URL
    }

    func makeContext() -> TestContext {
        let suiteName = "LLMServerDiagnosticsTests.\(UUID().uuidString)"
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
            fileName: "\(id).gguf",
            url: "https://example.com/\(id).gguf",
            sizeBytes: 1_024,
            quantization: "Q4_K_M",
            contextSize: 4_096
        )
    }

    func makeService(
        context: TestContext,
        models: [ModelInfo],
        selectedModelId: String
    ) -> LLMService {
        context.defaults.set(selectedModelId, forKey: selectedModelDefaultsKey)

        let rpcClient = RPCClient()
        let service = LLMService(
            defaults: context.defaults,
            registry: ModelRegistry(models: models),
            downloadManager: ModelDownloadManager(baseDirectoryURL: context.baseDirectoryURL),
            serverManager: ServerProcessManager(rpcClient: rpcClient),
            rpcClient: rpcClient
        )
        return service
    }
}
