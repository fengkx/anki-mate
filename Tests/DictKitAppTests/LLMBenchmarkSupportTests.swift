import Foundation
import XCTest
@testable import AnkiMateLLM

final class LLMBenchmarkSupportTests: XCTestCase {
    func testDefaultBenchmarkMatrixLoadsExpectedModels() throws {
        let matrix = try LLMBenchmarkMatrix.load(from: benchmarkMatrixURL())

        XCTAssertEqual(matrix.name, "default")
        XCTAssertEqual(
            matrix.models.map(\.modelId),
            [
                "gemma-4-e2b-it-q4km",
                "gemma-4-e2b-it-q6k",
                "gemma-3n-e4b-it-q4km",
                "gemma-3n-e4b-it-q6k",
                "qwen35-4b-q4km",
                "qwen35-4b-q6k"
            ]
        )
        XCTAssertEqual(Set(matrix.models.map(\.family)), ["gemma-4", "gemma-3n", "qwen35"])
    }

    func testBenchmarkReportWriterEmitsExpectedFilesAndSummaryContent() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let report = LLMBenchmarkReport(
            run: .init(
                startedAt: Date(timeIntervalSince1970: 1_710_000_000),
                finishedAt: Date(timeIntervalSince1970: 1_710_000_120),
                durationMilliseconds: 120_000,
                gitCommit: "abcdef1",
                gitBranch: "feature/benchmark",
                runnerOS: "macOS",
                machine: .init(cpu: "Apple M3", memoryGB: 36, macOSVersion: "15.0"),
                environment: .init(
                    threads: "8",
                    batchThreads: "8",
                    rounds: "1",
                    matrix: "default"
                ),
                github: .init(
                    workflow: "LLM Benchmark",
                    runID: "101",
                    runNumber: "22",
                    sha: "abcdef123456",
                    ref: "refs/heads/feature/benchmark",
                    eventName: "workflow_dispatch"
                )
            ),
            matrix: .init(
                name: "default",
                selectedModelIDs: ["gemma-4-e2b-it-q4km", "gemma-4-e2b-it-q6k"],
                executedModelIDs: ["gemma-4-e2b-it-q4km", "gemma-4-e2b-it-q6k"],
                skipped: [
                    .init(modelID: "gemma-3n-e4b-it-q4km", reason: "model_not_downloaded")
                ]
            ),
            models: [
                .init(
                    modelID: "gemma-4-e2b-it-q4km",
                    displayName: "Gemma 4 E2B Instruct (Q4_K_M)",
                    family: "gemma-4",
                    variant: "gemma-4-e2b-it",
                    quantization: "Q4_K_M",
                    sizeBytes: 3_106_735_776,
                    contextSize: 131_072,
                    status: .passed,
                    summary: .init(
                        totalTasks: 2,
                        passedTasks: 2,
                        failedTasks: 0,
                        warningCount: 1,
                        totalLatencyMilliseconds: 2_400,
                        averageLatencyMilliseconds: 1_200
                    ),
                    tasks: [
                        .init(
                            taskType: "example_sentences",
                            caseID: "light",
                            word: "light",
                            status: .passed,
                            latencyMilliseconds: 1_000,
                            hardFailures: [],
                            warnings: ["duplicate_examples"],
                            metrics: ["sense_coverage": .double(1.0)],
                            output: ["sample": .string("The lamp gave off a soft light. — 灯发出柔和的光。")]
                        ),
                        .init(
                            taskType: "recall_draft_decision",
                            caseID: "receive",
                            word: "receive",
                            status: .passed,
                            latencyMilliseconds: 1_400,
                            hardFailures: [],
                            warnings: [],
                            metrics: ["mode": .string("targeted_letter_cloze")],
                            output: ["front": .string("收到：r__eive")]
                        )
                    ]
                ),
                .init(
                    modelID: "gemma-4-e2b-it-q6k",
                    displayName: "Gemma 4 E2B Instruct (Q6_K)",
                    family: "gemma-4",
                    variant: "gemma-4-e2b-it",
                    quantization: "Q6_K",
                    sizeBytes: 4_501_718_688,
                    contextSize: 131_072,
                    status: .passed,
                    summary: .init(
                        totalTasks: 2,
                        passedTasks: 2,
                        failedTasks: 0,
                        warningCount: 0,
                        totalLatencyMilliseconds: 2_900,
                        averageLatencyMilliseconds: 1_450
                    ),
                    tasks: [
                        .init(
                            taskType: "example_sentences",
                            caseID: "light",
                            word: "light",
                            status: .passed,
                            latencyMilliseconds: 1_200,
                            hardFailures: [],
                            warnings: [],
                            metrics: ["sense_coverage": .double(1.0)],
                            output: ["sample": .string("Morning light poured through the window. — 晨光洒进窗户。")]
                        ),
                        .init(
                            taskType: "recall_draft_decision",
                            caseID: "receive",
                            word: "receive",
                            status: .passed,
                            latencyMilliseconds: 1_700,
                            hardFailures: [],
                            warnings: [],
                            metrics: ["mode": .string("targeted_letter_cloze")],
                            output: ["front": .string("收到：re__ve")]
                        )
                    ]
                )
            ]
        )

        try LLMBenchmarkReportWriter().write(report: report, to: directoryURL)

        let summary = try String(contentsOf: directoryURL.appendingPathComponent("summary.md"))
        let stepSummary = try String(contentsOf: directoryURL.appendingPathComponent("step-summary.md"))
        let environmentData = try Data(contentsOf: directoryURL.appendingPathComponent("environment.json"))
        let resultsData = try Data(contentsOf: directoryURL.appendingPathComponent("results.json"))

        XCTAssertTrue(summary.contains("LLM E2E Benchmark Report"))
        XCTAssertTrue(summary.contains("Gemma 4 E2B Instruct (Q4_K_M)"))
        XCTAssertTrue(summary.contains("Quantization Comparisons"))
        XCTAssertTrue(summary.contains("model_not_downloaded"))
        XCTAssertTrue(stepSummary.contains("LLM Benchmark Summary"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedEnvironment = try decoder.decode(LLMBenchmarkRunContext.self, from: environmentData)
        let decodedResults = try decoder.decode(LLMBenchmarkReport.self, from: resultsData)
        XCTAssertEqual(decodedEnvironment.gitCommit, "abcdef1")
        XCTAssertEqual(decodedResults.models.count, 2)
        XCTAssertEqual(decodedResults.matrix.skipped.first?.modelID, "gemma-3n-e4b-it-q4km")
    }

    private func benchmarkMatrixURL(file: StaticString = #filePath) -> URL {
        let testsDirectoryURL = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
        let repositoryRootURL = testsDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        return repositoryRootURL
            .appendingPathComponent("ci", isDirectory: true)
            .appendingPathComponent("llm-benchmark-matrix.json")
    }
}
