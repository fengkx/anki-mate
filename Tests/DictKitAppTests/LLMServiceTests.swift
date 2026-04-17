import AnkiMateRPC
import Combine
import XCTest
@testable import AnkiMateLLM

@MainActor
final class LLMServiceTests: XCTestCase {
    func testDownloadProgressFormatsSpeedAndETAForUsers() throws {
        let progress = ModelDownloadManager.DownloadProgress(
            modelId: "test-model",
            state: .downloading,
            bytesWritten: 50,
            totalBytes: 150,
            bytesPerSecond: 10
        )

        let remaining = try XCTUnwrap(progress.estimatedTimeRemaining)
        XCTAssertEqual(remaining, 10, accuracy: 0.001)
        XCTAssertNotNil(progress.formattedSpeed)
        XCTAssertTrue(progress.transferStatusText.contains("/s"))
        XCTAssertTrue(progress.transferStatusText.contains("left"))
    }

    func testDownloadProgressShowsConnectingStatesBeforeSpeedIsKnown() {
        let connecting = ModelDownloadManager.DownloadProgress(
            modelId: "test-model",
            state: .downloading,
            bytesWritten: 0,
            totalBytes: 150
        )
        let calculating = ModelDownloadManager.DownloadProgress(
            modelId: "test-model",
            state: .downloading,
            bytesWritten: 50,
            totalBytes: 150
        )

        XCTAssertEqual(connecting.transferStatusText, "Connecting...")
        XCTAssertEqual(calculating.transferStatusText, "Calculating speed...")
    }

    func testDownloadProgressCanCarryRecoverySuggestion() {
        let progress = ModelDownloadManager.DownloadProgress(
            modelId: "test-model",
            state: .failed("Connection timed out."),
            bytesWritten: 64,
            totalBytes: 150,
            recoverySuggestion: "Retry the download. If it keeps timing out, try a mirror."
        )

        XCTAssertEqual(
            progress.recoverySuggestion,
            "Retry the download. If it keeps timing out, try a mirror."
        )
    }

    func testDownloadManagerChangesTriggerLLMServiceUpdates() {
        let service = LLMService()
        let model = ModelInfo(
            id: "test-model",
            displayName: "Test Model",
            fileName: "test.gguf",
            url: "https://example.com/test.gguf",
            sizeBytes: 1024,
            quantization: "Q4_K_M",
            contextSize: 4096,
            recommended: false
        )

        let changed = expectation(description: "LLMService forwards download manager changes")
        var cancellables = Set<AnyCancellable>()

        service.objectWillChange
            .sink { _ in changed.fulfill() }
            .store(in: &cancellables)

        service.downloadManager.downloads[model.id] = .init(
            modelId: model.id,
            state: .downloading,
            bytesWritten: 128,
            totalBytes: model.sizeBytes,
            bytesPerSecond: 32
        )

        wait(for: [changed], timeout: 1.0)
    }

    func testActiveDownloadSummaryUsesHumanReadableTransferStatus() {
        let manager = ModelDownloadManager()
        manager.downloads["test-model"] = .init(
            modelId: "test-model",
            state: .downloading,
            bytesWritten: 200,
            totalBytes: 400,
            bytesPerSecond: 50
        )

        let summary = manager.activeDownloadSummary

        XCTAssertEqual(summary?.modelName, "test-model")
        XCTAssertEqual(summary?.fraction, 0.5)
        XCTAssertTrue(summary?.statusText.contains("/s") == true)
        XCTAssertTrue(summary?.statusText.contains("left") == true)
    }

    func testPersistedResumeStateRestoresAfterRelaunch() throws {
        let baseDirectoryURL = makeTemporaryDirectory()
        let progress = ModelDownloadManager.DownloadProgress(
            modelId: "test-model",
            state: .paused,
            bytesWritten: 128,
            totalBytes: 1024,
            recoverySuggestion: "Resume whenever you're ready."
        )
        let resumeData = Data([0x01, 0x02, 0x03])

        let first = ModelDownloadManager(baseDirectoryURL: baseDirectoryURL)
        try first.persistResumeState(for: "test-model", resumeData: resumeData, progress: progress)

        let second = ModelDownloadManager(baseDirectoryURL: baseDirectoryURL)

        XCTAssertTrue(second.canResume(modelId: "test-model"))
        XCTAssertEqual(second.downloads["test-model"]?.state, .paused)
        XCTAssertEqual(second.downloads["test-model"]?.bytesWritten, 128)
        XCTAssertEqual(second.downloads["test-model"]?.totalBytes, 1024)
    }

    func testCancelRemovesPersistedResumeState() throws {
        let baseDirectoryURL = makeTemporaryDirectory()
        let progress = ModelDownloadManager.DownloadProgress(
            modelId: "test-model",
            state: .paused,
            bytesWritten: 128,
            totalBytes: 1024
        )
        let resumeData = Data([0x01, 0x02, 0x03])

        let first = ModelDownloadManager(baseDirectoryURL: baseDirectoryURL)
        try first.persistResumeState(for: "test-model", resumeData: resumeData, progress: progress)
        first.cancel(modelId: "test-model")

        let second = ModelDownloadManager(baseDirectoryURL: baseDirectoryURL)

        XCTAssertFalse(second.canResume(modelId: "test-model"))
        XCTAssertNil(second.downloads["test-model"])
    }

    func testDeleteModelRemovesLocalFileAndClearsDeletingState() async throws {
        let baseDirectoryURL = makeTemporaryDirectory()
        let manager = ModelDownloadManager(baseDirectoryURL: baseDirectoryURL)
        let model = ModelInfo(
            id: "test-model",
            displayName: "Test Model",
            fileName: "test.gguf",
            url: "https://example.com/test.gguf",
            sizeBytes: 1024,
            quantization: "Q4_K_M",
            contextSize: 4096,
            recommended: false
        )

        let fileURL = manager.localPath(for: model)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("stub".utf8).write(to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        try await manager.deleteModel(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(manager.isDeleting(modelId: model.id))
    }

    func testResolveAutoSelectedModelPrefersCurrentDownloadedModel() {
        let models = [
            ModelInfo(id: "a", displayName: "A", fileName: "a.gguf", url: "https://example.com/a.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "b", displayName: "B", fileName: "b.gguf", url: "https://example.com/b.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048)
        ]

        let resolved = LLMService.resolveAutoSelectedModelId(
            currentSelectedModelId: "b",
            registryModels: models,
            downloadedModelIDs: ["a", "b"]
        )

        XCTAssertEqual(resolved, "b")
    }

    func testResolveAutoSelectedModelFallsBackToFirstDownloadedRegistryModel() {
        let models = [
            ModelInfo(id: "a", displayName: "A", fileName: "a.gguf", url: "https://example.com/a.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "b", displayName: "B", fileName: "b.gguf", url: "https://example.com/b.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "c", displayName: "C", fileName: "c.gguf", url: "https://example.com/c.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048)
        ]

        let resolved = LLMService.resolveAutoSelectedModelId(
            currentSelectedModelId: "missing",
            registryModels: models,
            downloadedModelIDs: ["c", "b"]
        )

        XCTAssertEqual(resolved, "b")
    }

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
