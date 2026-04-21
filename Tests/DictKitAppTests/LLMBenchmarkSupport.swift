import Foundation

struct LLMBenchmarkMatrix: Codable, Equatable {
    struct ModelSelection: Codable, Equatable {
        let modelId: String
        let family: String
        let variant: String
        let quantization: String
    }

    let name: String
    let models: [ModelSelection]

    static func load(from url: URL) throws -> LLMBenchmarkMatrix {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LLMBenchmarkMatrix.self, from: data)
    }
}

struct LLMBenchmarkRunContext: Codable, Equatable {
    struct Machine: Codable, Equatable {
        let cpu: String
        let memoryGB: Int
        let macOSVersion: String
    }

    struct Environment: Codable, Equatable {
        let threads: String
        let batchThreads: String
        let rounds: String
        let matrix: String
    }

    struct GitHubContext: Codable, Equatable {
        let workflow: String
        let runID: String
        let runNumber: String
        let sha: String
        let ref: String
        let eventName: String
    }

    let startedAt: Date
    let finishedAt: Date
    let durationMilliseconds: Int
    let gitCommit: String
    let gitBranch: String
    let runnerOS: String
    let machine: Machine
    let environment: Environment
    let github: GitHubContext
}

struct LLMBenchmarkReport: Codable, Equatable {
    struct MatrixStatus: Codable, Equatable {
        struct SkippedModel: Codable, Equatable {
            let modelID: String
            let reason: String
        }

        let name: String
        let selectedModelIDs: [String]
        let executedModelIDs: [String]
        let skipped: [SkippedModel]
    }

    struct ModelResult: Codable, Equatable {
        enum Status: String, Codable, Equatable {
            case passed
            case failed
            case skipped
        }

        struct Summary: Codable, Equatable {
            let totalTasks: Int
            let passedTasks: Int
            let failedTasks: Int
            let warningCount: Int
            let totalLatencyMilliseconds: Int
            let averageLatencyMilliseconds: Int
        }

        struct TaskResult: Codable, Equatable {
            let taskType: String
            let caseID: String
            let word: String
            let status: Status
            let latencyMilliseconds: Int
            let hardFailures: [String]
            let warnings: [String]
            let metrics: [String: JSONValue]
            let output: [String: JSONValue]
        }

        let modelID: String
        let displayName: String
        let family: String
        let variant: String
        let quantization: String
        let sizeBytes: Int64
        let contextSize: Int
        let status: Status
        let summary: Summary
        let tasks: [TaskResult]
    }

    let run: LLMBenchmarkRunContext
    let matrix: MatrixStatus
    let models: [ModelResult]
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var markdownText: String {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            return String(format: "%.2f", value)
        case .bool(let value):
            return value ? "true" : "false"
        case .array(let values):
            return values.map(\.markdownText).joined(separator: ", ")
        case .object(let values):
            return values
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.markdownText)" }
                .joined(separator: ", ")
        case .null:
            return "null"
        }
    }
}

struct LLMBenchmarkReportWriter {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder.dateEncodingStrategy = .iso8601
    }

    func write(report: LLMBenchmarkReport, to directoryURL: URL) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try encoder.encode(report).write(to: directoryURL.appendingPathComponent("results.json"))
        try encoder.encode(report.run).write(to: directoryURL.appendingPathComponent("environment.json"))
        try summaryMarkdown(for: report).write(
            to: directoryURL.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
        try stepSummaryMarkdown(for: report).write(
            to: directoryURL.appendingPathComponent("step-summary.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func summaryMarkdown(for report: LLMBenchmarkReport) -> String {
        var lines: [String] = []
        lines.append("# LLM E2E Benchmark Report")
        lines.append("")
        lines.append("## Run Overview")
        lines.append("")
        lines.append("- Commit: `\(report.run.gitCommit)`")
        lines.append("- Branch: `\(report.run.gitBranch)`")
        lines.append("- Runner OS: `\(report.run.runnerOS)`")
        lines.append("- Matrix: `\(report.matrix.name)`")
        lines.append("- Rounds: `\(report.run.environment.rounds)`")
        lines.append("")
        lines.append("## Matrix Overview")
        lines.append("")
        lines.append("| Model | Status | Note |")
        lines.append("| --- | --- | --- |")
        let skippedByID = Dictionary(uniqueKeysWithValues: report.matrix.skipped.map { ($0.modelID, $0.reason) })
        for modelID in report.matrix.selectedModelIDs {
            let status: String
            if report.matrix.executedModelIDs.contains(modelID) {
                status = report.models.first(where: { $0.modelID == modelID })?.status.rawValue ?? "executed"
            } else {
                status = "skipped"
            }
            lines.append("| `\(modelID)` | `\(status)` | \(skippedByID[modelID] ?? "") |")
        }
        for skipped in report.matrix.skipped where !report.matrix.selectedModelIDs.contains(skipped.modelID) {
            lines.append("| `\(skipped.modelID)` | `skipped` | \(skipped.reason) |")
        }
        lines.append("")
        lines.append("## Model Summary")
        lines.append("")
        lines.append("| Model | Quant | Pass Rate | Avg Latency (ms) | Warnings |")
        lines.append("| --- | --- | --- | ---: | ---: |")
        for model in report.models {
            lines.append(
                "| \(model.displayName) | `\(model.quantization)` | \(model.summary.passedTasks)/\(model.summary.totalTasks) | \(model.summary.averageLatencyMilliseconds) | \(model.summary.warningCount) |"
            )
        }
        lines.append("")
        let variantGroups = Dictionary(grouping: report.models, by: \.variant)
        if !variantGroups.isEmpty {
            lines.append("## Quantization Comparisons")
            lines.append("")
            for variant in variantGroups.keys.sorted() {
                let models = variantGroups[variant, default: []].sorted { $0.quantization < $1.quantization }
                guard models.count > 1 else { continue }
                lines.append("### \(variant)")
                lines.append("")
                lines.append("| Quant | Avg Latency (ms) | Failed Tasks | Warnings |")
                lines.append("| --- | ---: | ---: | ---: |")
                for model in models {
                    lines.append(
                        "| `\(model.quantization)` | \(model.summary.averageLatencyMilliseconds) | \(model.summary.failedTasks) | \(model.summary.warningCount) |"
                    )
                }
                lines.append("")
            }
        }
        lines.append("")
        lines.append("## Task Samples")
        lines.append("")
        for model in report.models {
            lines.append("### \(model.displayName)")
            lines.append("")
            for task in model.tasks {
                let sample = task.output.sorted { $0.key < $1.key }.first.map { "\($0.key): \($0.value.markdownText)" } ?? "no output"
                lines.append("- `\(task.taskType)` / `\(task.word)`: \(sample)")
                if task.status == .failed, !task.hardFailures.isEmpty {
                    lines.append("  - failures: \(task.hardFailures.joined(separator: "; "))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func stepSummaryMarkdown(for report: LLMBenchmarkReport) -> String {
        var lines: [String] = []
        lines.append("## LLM Benchmark Summary")
        lines.append("")
        lines.append("- Matrix: `\(report.matrix.name)`")
        lines.append("- Models selected: \(report.matrix.selectedModelIDs.count)")
        lines.append("- Models executed: \(report.matrix.executedModelIDs.count)")
        if !report.matrix.skipped.isEmpty {
            lines.append("- Skipped: \(report.matrix.skipped.map { "\($0.modelID) (\($0.reason))" }.joined(separator: ", "))")
        }
        lines.append("")
        for model in report.models {
            lines.append("- \(model.displayName) (`\(model.modelID)`): \(model.summary.passedTasks)/\(model.summary.totalTasks) tasks passed, avg \(model.summary.averageLatencyMilliseconds) ms")
            for task in model.tasks where task.status == .failed {
                let failures = task.hardFailures.isEmpty ? "no hard failure details" : task.hardFailures.joined(separator: "; ")
                lines.append("  - failed `\(task.taskType)` / `\(task.word)`: \(failures)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
