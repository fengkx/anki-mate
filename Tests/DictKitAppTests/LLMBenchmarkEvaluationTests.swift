import XCTest
@testable import AnkiMateLLM

final class LLMBenchmarkEvaluationTests: XCTestCase {
    func testUsageExpectedLineCountMatchesProductStreamingContract() {
        XCTAssertEqual(
            LLMBenchmarkUsageEvaluation.expectedLineCount(
                for: [LLMSensePromptInput(partOfSpeech: "adjective", definition: "never ending")]
            ),
            2
        )

        XCTAssertEqual(
            LLMBenchmarkUsageEvaluation.expectedLineCount(
                for: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "fill a battery")
                ]
            ),
            3
        )
    }

    func testUsageAssessmentPromotesQualityProblemsToPassedWithIssues() {
        let result = LLMBenchmarkUsageEvaluation.assess(
            lines: [
                "Formal accusation. — 正式指控。",
                "Formal accusation. — 正式指控。"
            ],
            expectedCount: 3,
            isPlainBilingualLine: { $0.contains("—") }
        )

        XCTAssertEqual(result.status, .passedWithIssues)
        XCTAssertTrue(result.hardFailures.isEmpty)
        XCTAssertEqual(result.qualityIssues, ["line_count_mismatch", "repetition_detected"])
        XCTAssertEqual(
            result.warnings,
            []
        )
        XCTAssertEqual(result.metrics["expected_count"], .int(3))
        XCTAssertEqual(result.metrics["actual_count"], .int(2))
    }

    func testUsageAssessmentFlagsFormattingNoiseAsQualityIssue() {
        let result = LLMBenchmarkUsageEvaluation.assess(
            lines: ["1. formal accusation"],
            expectedCount: 1,
            isPlainBilingualLine: { $0.contains("—") }
        )

        XCTAssertEqual(result.status, .passedWithIssues)
        XCTAssertEqual(result.qualityIssues, ["formatting_noise"])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.hardFailures.isEmpty)
    }

    func testBenchmarkErrorClassificationTreatsInvalidStructuredOutputAsQualityIssue() {
        XCTAssertEqual(
            LLMBenchmarkErrorEvaluation.qualityIssues(
                from: LLMServiceError.invalidStructuredOutput(
                    "Recall draft generation returned no valid draft JSON"
                )
            ),
            ["invalid_structured_output: Recall draft generation returned no valid draft JSON"]
        )
    }

    func testBenchmarkErrorClassificationDoesNotDowngradeTransportTimeout() {
        XCTAssertNil(
            LLMBenchmarkErrorEvaluation.qualityIssues(
                from: URLError(.timedOut)
            )
        )
    }
}
