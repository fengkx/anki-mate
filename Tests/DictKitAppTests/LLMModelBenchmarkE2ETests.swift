import Foundation
import XCTest
@testable import AnkiMateLLM

@MainActor
final class LLMModelBenchmarkE2ETests: XCTestCase {
    private let runFlag = "DICTKIT_RUN_LLM_E2E_TESTS"
    private let reportDirectoryFlag = "DICTKIT_LLM_E2E_REPORT_DIR"
    private let roundsFlag = "DICTKIT_LLM_E2E_BENCHMARK_ROUNDS"
    private let matrixFlag = "DICTKIT_LLM_E2E_MATRIX"

    func testBenchmarkAcrossConfiguredModelsWritesReportWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[runFlag] == "1" else {
            throw XCTSkip("Set \(runFlag)=1 or run `just test-llm-benchmark` to execute optional benchmark tests.")
        }

        let suiteStart = Date()
        let matrixURL = benchmarkMatrixURL(named: environment[matrixFlag] ?? "default")
        let matrix = try LLMBenchmarkMatrix.load(from: matrixURL)
        let reportDirectoryURL = reportDirectoryURL()
        let rounds = max(1, Int(environment[roundsFlag] ?? "1") ?? 1)
        let service = LLMService()
        defer { Task { await service.stopServer() } }

        let registryByID = Dictionary(uniqueKeysWithValues: service.registry.models.map { ($0.id, $0) })
        let selectedModelIDs = matrix.models.map(\.modelId)
        var executedModelIDs: [String] = []
        var skippedModels: [LLMBenchmarkReport.MatrixStatus.SkippedModel] = []
        var modelResults: [LLMBenchmarkReport.ModelResult] = []

        for selection in matrix.models {
            guard let model = registryByID[selection.modelId] else {
                skippedModels.append(.init(modelID: selection.modelId, reason: "missing_from_registry"))
                continue
            }
            guard service.downloadManager.isDownloaded(model) else {
                skippedModels.append(.init(modelID: selection.modelId, reason: "model_not_downloaded"))
                continue
            }

            executedModelIDs.append(selection.modelId)
            service.selectedModelId = selection.modelId
            let tasks = try await runBenchmarkTasks(service: service, rounds: rounds)
            let failedTasks = tasks.filter { $0.status == .failed }.count
            let passedTasks = tasks.filter { $0.status == .passed }.count
            let warningCount = tasks.reduce(0) { $0 + $1.warnings.count }
            let totalLatency = tasks.reduce(0) { $0 + $1.latencyMilliseconds }
            let averageLatency = tasks.isEmpty ? 0 : totalLatency / tasks.count

            modelResults.append(
                .init(
                    modelID: model.id,
                    displayName: model.displayName,
                    family: selection.family,
                    variant: selection.variant,
                    quantization: selection.quantization,
                    sizeBytes: model.sizeBytes,
                    contextSize: model.contextSize,
                    status: failedTasks == 0 ? .passed : .failed,
                    summary: .init(
                        totalTasks: tasks.count,
                        passedTasks: passedTasks,
                        failedTasks: failedTasks,
                        warningCount: warningCount,
                        totalLatencyMilliseconds: totalLatency,
                        averageLatencyMilliseconds: averageLatency
                    ),
                    tasks: tasks
                )
            )

            await service.stopServer()
        }

        let report = LLMBenchmarkReport(
            run: makeRunContext(
                matrixName: matrix.name,
                startedAt: suiteStart,
                finishedAt: Date()
            ),
            matrix: .init(
                name: matrix.name,
                selectedModelIDs: selectedModelIDs,
                executedModelIDs: executedModelIDs,
                skipped: skippedModels
            ),
            models: modelResults
        )
        try LLMBenchmarkReportWriter().write(report: report, to: reportDirectoryURL)

        if executedModelIDs.isEmpty {
            throw XCTSkip("No benchmark models are downloaded. Run `just prepare-llm-benchmark-models` first.")
        }
    }
}

private extension LLMModelBenchmarkE2ETests {
    struct ExampleCase {
        let word: String
        let senses: [LLMSensePromptInput]
        let expectedCount: Int
        let requiredSenseCoverage: Set<Int>
    }

    struct UsageCase {
        let word: String
        let senses: [LLMSensePromptInput]
    }

    struct RecallCase {
        let word: String
        let senses: [LLMSensePromptInput]
        let acceptedPitfalls: [String]
        let acceptedDefinitionNote: String?
        let acceptedMnemonics: [String]
        let acceptedCollocations: [String]
        let previewAnchor: LLMAnchorSnapshot?
        let expectedMode: LLMRecallCardMode
    }

    struct LearningAidsCase {
        let word: String
        let senses: [LLMSensePromptInput]
        let acceptedPitfalls: [String]
        let acceptedDefinitionNote: String?
        let acceptedMnemonics: [String]
        let acceptedCollocations: [String]
        let anchor: LLMAnchorSnapshot?
    }

    var exampleCases: [ExampleCase] {
        [
            .init(
                word: "light",
                senses: [
                    .init(partOfSpeech: "noun", definition: "illumination"),
                    .init(partOfSpeech: "adjective", definition: "not heavy"),
                    .init(partOfSpeech: "verb", definition: "ignite")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1, 2, 3]
            ),
            .init(
                word: "perpetual",
                senses: [
                    .init(partOfSpeech: "adjective", definition: "continuing forever or for a very long time")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1]
            ),
            .init(
                word: "charge",
                senses: [
                    .init(partOfSpeech: "noun", definition: "formal accusation"),
                    .init(partOfSpeech: "verb", definition: "ask someone to pay a price"),
                    .init(partOfSpeech: "verb", definition: "fill a battery")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1, 2, 3]
            )
        ]
    }

    var usageCases: [UsageCase] {
        [
            .init(
                word: "charge",
                senses: [
                    .init(partOfSpeech: "noun", definition: "formal accusation"),
                    .init(partOfSpeech: "verb", definition: "ask someone to pay a price"),
                    .init(partOfSpeech: "verb", definition: "fill a battery")
                ]
            ),
            .init(
                word: "light",
                senses: [
                    .init(partOfSpeech: "noun", definition: "illumination"),
                    .init(partOfSpeech: "adjective", definition: "not heavy"),
                    .init(partOfSpeech: "verb", definition: "ignite")
                ]
            )
        ]
    }

    var recallCases: [RecallCase] {
        [
            .init(
                word: "take off",
                senses: [.init(partOfSpeech: "verb", definition: "起飞；脱下", semanticHint: "起飞")],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "在飞机语境中表示起飞",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .phraseRecall
            ),
            .init(
                word: "receive",
                senses: [.init(partOfSpeech: "verb", definition: "收到；接收", semanticHint: "收到")],
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"],
                acceptedDefinitionNote: nil,
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze
            ),
            .init(
                word: "collocation",
                senses: [.init(partOfSpeech: "noun", definition: "固定搭配；常见词语搭配", semanticHint: "常见词语搭配")],
                acceptedPitfalls: ["容易漏掉双写的 ll"],
                acceptedDefinitionNote: "指自然的词语搭配，不是任意两个词放在一起",
                acceptedMnemonics: [],
                acceptedCollocations: ["strong collocation"],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze
            ),
            .init(
                word: "perpetual",
                senses: [.init(partOfSpeech: "adjective", definition: "持续不断的；长期不止的", semanticHint: "持续不断的")],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "常用于表示问题、噪音、争论等持续不止",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .fullSpelling
            )
        ]
    }

    var learningAidsCases: [LearningAidsCase] {
        [
            .init(
                word: "principal",
                senses: [
                    .init(partOfSpeech: "noun", definition: "head of a school"),
                    .init(partOfSpeech: "adjective", definition: "most important")
                ],
                acceptedPitfalls: ["不要和 principle 混淆"],
                acceptedDefinitionNote: "作名词时可指学校负责人",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            .init(
                word: "receive",
                senses: [
                    .init(partOfSpeech: "verb", definition: "get or be given something")
                ],
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"],
                acceptedDefinitionNote: "表示收到某物，不只是正式接收",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            .init(
                word: "collocation",
                senses: [
                    .init(partOfSpeech: "noun", definition: "habitual word pairing", semanticHint: "word pairing")
                ],
                acceptedPitfalls: ["容易漏掉双写的 ll"],
                acceptedDefinitionNote: "指自然的词语搭配，不是任意两个词放在一起",
                acceptedMnemonics: [],
                acceptedCollocations: ["strong collocation"],
                anchor: nil
            )
        ]
    }

    func runBenchmarkTasks(
        service: LLMService,
        rounds: Int
    ) async throws -> [LLMBenchmarkReport.ModelResult.TaskResult] {
        var tasks: [LLMBenchmarkReport.ModelResult.TaskResult] = []
        for _ in 0..<rounds {
            for testCase in exampleCases {
                tasks.append(await runExampleTask(service: service, testCase: testCase))
            }
            for testCase in usageCases {
                tasks.append(await runUsageTask(service: service, testCase: testCase))
            }
            for testCase in recallCases {
                tasks.append(await runRecallTask(service: service, testCase: testCase))
            }
            for testCase in learningAidsCases {
                tasks.append(await runLearningAidsTask(service: service, testCase: testCase))
            }
        }
        return tasks
    }

    func runExampleTask(
        service: LLMService,
        testCase: ExampleCase
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(taskType: "example_sentences", caseID: testCase.word, word: testCase.word) {
            let examples = try await service.generateExampleSentenceArtifacts(
                word: testCase.word,
                senses: testCase.senses
            )
            var failures: [String] = []
            let coveredSenseIndexes = Set(examples.compactMap(\.senseIndex))
            if examples.count != testCase.expectedCount {
                failures.append("expected_count_mismatch")
            }
            if Set(examples.map(\.english)).count != examples.count {
                failures.append("duplicate_examples")
            }
            if !testCase.requiredSenseCoverage.isSubset(of: coveredSenseIndexes) {
                failures.append("missing_sense_coverage")
            }
            if !examples.allSatisfy({ isPlainText($0.english) && isPlainText($0.translation) }) {
                failures.append("formatting_noise")
            }
            let duplicateRate = examples.isEmpty ? 0.0 : Double(examples.count - Set(examples.map(\.english)).count) / Double(examples.count)
            return .init(
                status: failures.isEmpty ? .passed : .failed,
                hardFailures: failures,
                warnings: duplicateRate > 0 ? ["duplicate_examples"] : [],
                metrics: [
                    "expected_count": .int(testCase.expectedCount),
                    "actual_count": .int(examples.count),
                    "sense_coverage": .double(Double(coveredSenseIndexes.count) / Double(max(1, testCase.requiredSenseCoverage.count))),
                    "duplicate_rate": .double(duplicateRate)
                ],
                output: [
                    "examples": .array(
                        examples.map {
                            .object([
                                "english": .string($0.english),
                                "translation": .string($0.translation),
                                "sense_index": $0.senseIndex.map(JSONValue.int) ?? .null
                            ])
                        }
                    )
                ]
            )
        }
    }

    func runUsageTask(
        service: LLMService,
        testCase: UsageCase
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(taskType: "usage_hints", caseID: testCase.word, word: testCase.word) {
            let hint = try await service.optimizeDefinition(word: testCase.word, senses: testCase.senses)
            let lines = normalizedNonEmptyLines(from: hint)
            var failures: [String] = []
            if lines.count != testCase.senses.count {
                failures.append("line_count_mismatch")
            }
            if !lines.allSatisfy(isPlainBilingualLine(_:)) {
                failures.append("formatting_noise")
            }
            let repetitionFlag = Set(lines).count != lines.count
            return .init(
                status: failures.isEmpty ? .passed : .failed,
                hardFailures: failures,
                warnings: repetitionFlag ? ["repetition_detected"] : [],
                metrics: [
                    "expected_count": .int(testCase.senses.count),
                    "actual_count": .int(lines.count),
                    "plain_text": .bool(lines.allSatisfy(isPlainBilingualLine(_:)))
                ],
                output: [
                    "lines": .array(lines.map(JSONValue.string))
                ]
            )
        }
    }

    func runRecallTask(
        service: LLMService,
        testCase: RecallCase
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(taskType: "recall_draft_decision", caseID: testCase.word, word: testCase.word) {
            let context = LLMService.normalizeRecallGenerationContext(
                .init(
                    acceptedPitfalls: testCase.acceptedPitfalls,
                    acceptedUsageHints: acceptedUsageHints(from: testCase.acceptedDefinitionNote),
                    acceptedMnemonics: testCase.acceptedMnemonics,
                    acceptedCollocations: testCase.acceptedCollocations
                )
            )
            let allowedModes = LLMService.recommendedRecallAllowedModes(for: testCase.word, context: context)
            let modePrior = LLMService.recommendedRecallModePrior(for: testCase.word, context: context, allowedModes: allowedModes)
            let decision = try await service.generateRecallCardDraftDecision(
                word: testCase.word,
                senses: testCase.senses,
                context: context,
                allowedModes: allowedModes,
                modePrior: modePrior,
                anchor: testCase.previewAnchor
            )

            var failures: [String] = []
            if decision.draft.front.isEmpty || decision.draft.back.isEmpty {
                failures.append("empty_card_side")
            }
            if decision.draft.back != testCase.word {
                failures.append("back_side_changed")
            }
            if !allowedModes.contains(decision.draft.mode) {
                failures.append("disallowed_mode")
            }
            if !isPlainText(decision.draft.front) || !isPlainText(decision.draft.back) {
                failures.append("formatting_noise")
            }
            if cuePlanContainsTarget(decision.draft.front, target: testCase.word) {
                failures.append("target_leak")
            }
            if decision.draft.mode == .targetedLetterCloze {
                if underscoreGroupCount(in: decision.draft.front) != 1 {
                    failures.append("invalid_cloze_shape")
                }
                let gapLength = longestUnderscoreRun(in: decision.draft.front)
                if !(2...3).contains(gapLength) {
                    failures.append("invalid_cloze_gap_length")
                }
            }

            return .init(
                status: failures.isEmpty ? .passed : .failed,
                hardFailures: failures,
                warnings: decision.draft.mode != testCase.expectedMode ? ["mode_differs_from_baseline"] : [],
                metrics: [
                    "mode": .string(decision.draft.mode.rawValue),
                    "expected_mode": .string(testCase.expectedMode.rawValue),
                    "front_clean": .bool(isPlainText(decision.draft.front)),
                    "target_leak": .bool(cuePlanContainsTarget(decision.draft.front, target: testCase.word))
                ],
                output: [
                    "front": .string(decision.draft.front),
                    "back": .string(decision.draft.back),
                    "hint": decision.draft.hint.map(JSONValue.string) ?? .null,
                    "selection_reason": .string(decision.selectionReason?.primaryGoal ?? ""),
                    "cue_plan": .string(decision.cuePlan?.normalizedCue ?? "")
                ]
            )
        }
    }

    func runLearningAidsTask(
        service: LLMService,
        testCase: LearningAidsCase
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(taskType: "learning_aids", caseID: testCase.word, word: testCase.word) {
            let ranked = try await service.generateRankedLearningAids(
                word: testCase.word,
                senses: testCase.senses,
                acceptedContext: .init(
                    acceptedPitfalls: testCase.acceptedPitfalls,
                    acceptedUsageHints: testCase.acceptedDefinitionNote.map { [$0] } ?? [],
                    acceptedMnemonics: testCase.acceptedMnemonics,
                    acceptedCollocations: testCase.acceptedCollocations
                ),
                anchor: testCase.anchor
            )
            let aids = ranked.aids
            var failures: [String] = []
            if !isLearningAidResultWellFormed(ranked) {
                failures.append("invalid_section_selection")
            }
            if !aids.pitfalls.allSatisfy({ isPlainText($0.summary) && !startsWithListMarker($0.summary) }) {
                failures.append("pitfall_formatting_noise")
            }
            if !aids.mnemonics.allSatisfy({ isPlainText($0.clue) && $0.clue.count <= 80 }) {
                failures.append("mnemonic_formatting_noise")
            }
            if !aids.collocations.allSatisfy({
                isPlainText($0.phrase)
                    && !$0.phrase.contains("\n")
                    && !$0.phrase.hasSuffix(".")
                    && !$0.phrase.hasSuffix("!")
                    && !$0.phrase.hasSuffix("?")
            }) {
                failures.append("collocation_formatting_noise")
            }

            let overlapScores = [
                ranked.selections.pitfalls.flatMap { sectionSummary(selection: $0, textByID: Dictionary(uniqueKeysWithValues: aids.pitfalls.map { ($0.id, $0.summary) }), senses: testCase.senses) },
                ranked.selections.mnemonics.flatMap { sectionSummary(selection: $0, textByID: Dictionary(uniqueKeysWithValues: aids.mnemonics.map { ($0.id, $0.clue) }), senses: testCase.senses) },
                ranked.selections.collocations.flatMap { sectionSummary(selection: $0, textByID: Dictionary(uniqueKeysWithValues: aids.collocations.map { ($0.id, $0.phrase) }), senses: testCase.senses) }
            ].compactMap { $0?.overlap }

            let averageOverlap = overlapScores.isEmpty ? 0.0 : overlapScores.reduce(0, +) / Double(overlapScores.count)

            return .init(
                status: failures.isEmpty ? .passed : .failed,
                hardFailures: failures,
                warnings: averageOverlap > 0.5 ? ["high_definition_overlap"] : [],
                metrics: [
                    "pitfalls_count": .int(aids.pitfalls.count),
                    "mnemonics_count": .int(aids.mnemonics.count),
                    "collocations_count": .int(aids.collocations.count),
                    "definition_overlap": .double(averageOverlap),
                    "selection_complete": .bool(isLearningAidResultWellFormed(ranked))
                ],
                output: [
                    "pitfall": .string(sectionSummary(selection: ranked.selections.pitfalls, textByID: Dictionary(uniqueKeysWithValues: aids.pitfalls.map { ($0.id, $0.summary) }), senses: testCase.senses)?.text ?? ""),
                    "mnemonic": .string(sectionSummary(selection: ranked.selections.mnemonics, textByID: Dictionary(uniqueKeysWithValues: aids.mnemonics.map { ($0.id, $0.clue) }), senses: testCase.senses)?.text ?? ""),
                    "collocation": .string(sectionSummary(selection: ranked.selections.collocations, textByID: Dictionary(uniqueKeysWithValues: aids.collocations.map { ($0.id, $0.phrase) }), senses: testCase.senses)?.text ?? "")
                ]
            )
        }
    }

    func measureTask(
        taskType: String,
        caseID: String,
        word: String,
        operation: () async throws -> MeasuredTaskOutcome
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let outcome = try await operation()
            let elapsed = start.duration(to: clock.now)
            return .init(
                taskType: taskType,
                caseID: caseID,
                word: word,
                status: outcome.status,
                latencyMilliseconds: elapsed.milliseconds,
                hardFailures: outcome.hardFailures,
                warnings: outcome.warnings,
                metrics: outcome.metrics,
                output: outcome.output
            )
        } catch {
            let elapsed = start.duration(to: clock.now)
            return .init(
                taskType: taskType,
                caseID: caseID,
                word: word,
                status: .failed,
                latencyMilliseconds: elapsed.milliseconds,
                hardFailures: [String(reflecting: error)],
                warnings: [],
                metrics: [:],
                output: [:]
            )
        }
    }

    struct MeasuredTaskOutcome {
        let status: LLMBenchmarkReport.ModelResult.Status
        let hardFailures: [String]
        let warnings: [String]
        let metrics: [String: JSONValue]
        let output: [String: JSONValue]
    }

    struct SectionSummary {
        let text: String
        let overlap: Double
    }

    func sectionSummary(
        selection: LLMLearningAidSectionSelection?,
        textByID: [String: String],
        senses: [LLMSensePromptInput]
    ) -> SectionSummary? {
        guard let selection,
              let recommendedID = selection.recommendedID,
              let text = textByID[recommendedID] else {
            return nil
        }
        return .init(text: text, overlap: definitionOverlap(of: text, senses: senses))
    }

    func isLearningAidResultWellFormed(_ ranked: LLMLearningAidsRankedResult) -> Bool {
        let aids = ranked.aids
        return isLearningAidSectionWellFormed(items: aids.pitfalls.map(\.id), selection: ranked.selections.pitfalls)
            && isLearningAidSectionWellFormed(items: aids.mnemonics.map(\.id), selection: ranked.selections.mnemonics)
            && isLearningAidSectionWellFormed(items: aids.collocations.map(\.id), selection: ranked.selections.collocations)
    }

    func isLearningAidSectionWellFormed(items: [String], selection: LLMLearningAidSectionSelection?) -> Bool {
        if items.isEmpty {
            return selection == nil || selection?.recommendedID == nil
        }
        guard let selection else { return false }
        if let recommendedID = selection.recommendedID, !items.contains(recommendedID) {
            return false
        }
        return selection.alternativeIDs.allSatisfy(items.contains)
    }

    func normalizedNonEmptyLines(from text: String) -> [String] {
        text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func isPlainBilingualLine(_ line: String) -> Bool {
        line.contains("—") && isPlainText(line)
    }

    func isPlainText(_ text: String) -> Bool {
        !text.contains("```")
            && !text.contains("EN:")
            && !text.contains("ZH:")
            && !startsWithListMarker(text)
    }

    func startsWithListMarker(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: #"^(?:[-*•]\s+|\d+\s*[\.\)\:\-–—]\s+)"#, options: .regularExpression) != nil
    }

    func underscoreGroupCount(in text: String) -> Int {
        var count = 0
        var previousWasUnderscore = false
        for character in text {
            if character == "_" {
                if !previousWasUnderscore {
                    count += 1
                }
                previousWasUnderscore = true
            } else {
                previousWasUnderscore = false
            }
        }
        return count
    }

    func longestUnderscoreRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            if character == "_" {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }

    func cuePlanContainsTarget(_ cue: String, target: String) -> Bool {
        let normalizedCue = cue.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedTarget = target.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalizedCue.isEmpty, !normalizedTarget.isEmpty else { return false }
        if normalizedTarget.contains(" ") {
            return normalizedCue.contains(normalizedTarget)
        }
        let pattern = #"(?<![[:alnum:]])\#(NSRegularExpression.escapedPattern(for: normalizedTarget))(?![[:alnum:]])"#
        return normalizedCue.range(of: pattern, options: .regularExpression) != nil
    }

    func acceptedUsageHints(from note: String?) -> [String] {
        guard let note else { return [] }
        return note
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func definitionOverlap(of text: String, senses: [LLMSensePromptInput]) -> Double {
        let candidateTokens = overlapTokens(from: text)
        guard !candidateTokens.isEmpty else { return 0 }
        var best = 0.0
        for sense in senses {
            let senseText = [sense.definition, sense.semanticHint].compactMap { $0 }.joined(separator: " ")
            let senseTokens = overlapTokens(from: senseText)
            guard !senseTokens.isEmpty else { continue }
            let overlap = Double(Set(candidateTokens).intersection(senseTokens).count)
                / Double(max(1, min(candidateTokens.count, senseTokens.count)))
            best = max(best, overlap)
        }
        return best
    }

    func overlapTokens(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "an", "and", "as", "be", "by", "for", "from", "in", "is", "it", "of", "or", "the",
            "to", "with", "without", "on", "at", "into", "than", "that", "this", "these", "those",
            "are", "was", "were", "am", "been", "being"
        ]
        return text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
    }

    func reportDirectoryURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment[reportDirectoryFlag], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("llm-benchmark-report", isDirectory: true)
    }

    func benchmarkMatrixURL(named name: String) -> URL {
        let testsDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRootURL = testsDirectoryURL.deletingLastPathComponent().deletingLastPathComponent()
        return repositoryRootURL
            .appendingPathComponent("ci", isDirectory: true)
            .appendingPathComponent("llm-benchmark-matrix.json")
    }

    func makeRunContext(
        matrixName: String,
        startedAt: Date,
        finishedAt: Date
    ) -> LLMBenchmarkRunContext {
        let environment = ProcessInfo.processInfo.environment
        return .init(
            startedAt: startedAt,
            finishedAt: finishedAt,
            durationMilliseconds: Int(finishedAt.timeIntervalSince(startedAt) * 1_000),
            gitCommit: shell("git", arguments: ["rev-parse", "--short", "HEAD"]) ?? environment["GITHUB_SHA"] ?? "unknown",
            gitBranch: shell("git", arguments: ["branch", "--show-current"]) ?? environment["GITHUB_REF_NAME"] ?? "unknown",
            runnerOS: environment["RUNNER_OS"] ?? ProcessInfo.processInfo.operatingSystemVersionString,
            machine: .init(
                cpu: shell("/usr/sbin/sysctl", arguments: ["-n", "machdep.cpu.brand_string"]) ?? "unknown",
                memoryGB: Int((Double(shell("/usr/sbin/sysctl", arguments: ["-n", "hw.memsize"]) ?? "0") ?? 0) / 1_000_000_000),
                macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            environment: .init(
                threads: environment["DICTKIT_LLM_THREADS"] ?? "default",
                batchThreads: environment["DICTKIT_LLM_THREADS_BATCH"] ?? "default",
                rounds: environment[roundsFlag] ?? "1",
                matrix: matrixName
            ),
            github: .init(
                workflow: environment["GITHUB_WORKFLOW"] ?? "local",
                runID: environment["GITHUB_RUN_ID"] ?? "",
                runNumber: environment["GITHUB_RUN_NUMBER"] ?? "",
                sha: environment["GITHUB_SHA"] ?? "",
                ref: environment["GITHUB_REF"] ?? "",
                eventName: environment["GITHUB_EVENT_NAME"] ?? "local"
            )
        )
    }

    func shell(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

private extension Duration {
    var milliseconds: Int {
        Int(
            Double(components.seconds) * 1_000
                + Double(components.attoseconds) / 1_000_000_000_000_000
        )
    }
}
