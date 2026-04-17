import XCTest
@testable import AnkiMateLLM

@MainActor
final class LLMServiceE2ETests: XCTestCase {
    private let runFlag = "DICTKIT_RUN_LLM_E2E_TESTS"
    private let modelFlag = "DICTKIT_LLM_E2E_MODEL_ID"

    func testE2EExampleGenerationRespectsMultiSenseInventoryWhenEnabled() async throws {
        let service = try configuredServiceOrSkip()
        defer { Task { await service.stopServer() } }

        let senses = [
            LLMSensePromptInput(partOfSpeech: "noun", definition: "illumination"),
            LLMSensePromptInput(partOfSpeech: "adjective", definition: "not heavy"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "ignite")
        ]

        let sentences = try await service.generateExampleSentences(
            word: "light",
            senses: senses
        )

        XCTAssertEqual(sentences.count, senses.count)
        XCTAssertEqual(Set(sentences).count, sentences.count)
        XCTAssertTrue(sentences.allSatisfy { $0.contains("—") })
    }

    func testE2EUsageHintReturnsOneLinePerSenseWhenEnabled() async throws {
        let service = try configuredServiceOrSkip()
        defer { Task { await service.stopServer() } }

        let senses = [
            LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "fill a battery")
        ]

        let hint = try await service.optimizeDefinition(
            word: "charge",
            senses: senses
        )

        let lines = hint
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, senses.count)
        XCTAssertTrue(lines.allSatisfy { $0.contains("—") })
        XCTAssertFalse(lines.contains { $0.contains("EN:") || $0.contains("ZH:") })
    }

    private func configuredServiceOrSkip() throws -> LLMService {
        let environment = ProcessInfo.processInfo.environment
        guard environment[runFlag] == "1" else {
            throw XCTSkip("Set \(runFlag)=1 to run optional LLM end-to-end tests.")
        }

        let service = LLMService()
        let downloadedModels = service.registry.models.filter { service.downloadManager.isDownloaded($0) }
        guard !downloadedModels.isEmpty else {
            throw XCTSkip("No downloaded LLM model found for optional end-to-end tests.")
        }

        if let requestedModelId = environment[modelFlag], !requestedModelId.isEmpty {
            guard downloadedModels.contains(where: { $0.id == requestedModelId }) else {
                throw XCTSkip("Requested model \(requestedModelId) is not downloaded.")
            }
            service.selectedModelId = requestedModelId
        } else if service.selectedModelId.isEmpty || !downloadedModels.contains(where: { $0.id == service.selectedModelId }) {
            service.selectedModelId = downloadedModels[0].id
        }

        return service
    }
}
