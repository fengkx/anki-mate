import Foundation
@testable import AnkiMateLLM

enum LLMBenchmarkErrorEvaluation {
    static func qualityIssues(from error: Error) -> [String]? {
        switch error {
        case LLMServiceError.invalidStructuredOutput(let message):
            return ["invalid_structured_output: \(message)"]
        case AgentToolRegistryError.invalidArguments(let toolName):
            return ["invalid_agent_tool_arguments: \(toolName)"]
        default:
            return nil
        }
    }
}

struct LLMBenchmarkUsageEvaluation {
    static func expectedLineCount(for senses: [LLMSensePromptInput]) -> Int {
        LLMPrompt.usageHintCount(for: senses)
    }

    static func assess(
        lines: [String],
        expectedCount: Int,
        isPlainBilingualLine: (String) -> Bool
    ) -> LLMBenchmarkReport.ModelResult.TaskResult {
        var qualityIssues: [String] = []
        if lines.count != expectedCount {
            qualityIssues.append("line_count_mismatch")
        }
        if !lines.allSatisfy(isPlainBilingualLine) {
            qualityIssues.append("formatting_noise")
        }
        if Set(lines).count != lines.count {
            qualityIssues.append("repetition_detected")
        }

        return .init(
            taskType: "usage_hints",
            caseID: "usage-eval",
            word: "usage",
            status: qualityIssues.isEmpty ? .passed : .passedWithIssues,
            latencyMilliseconds: 0,
            hardFailures: [],
            qualityIssues: qualityIssues,
            warnings: [],
            metrics: [
                "expected_count": .int(expectedCount),
                "actual_count": .int(lines.count),
                "plain_text": .bool(lines.allSatisfy(isPlainBilingualLine))
            ],
            output: [
                "lines": .array(lines.map(JSONValue.string))
            ],
            traceFile: nil,
            traceSessionIDs: []
        )
    }
}
