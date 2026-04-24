import Foundation
import XCTest
@testable import AnkiMateLLM
@testable import AnkiMateRPC
@testable import DictKitAnkiExport

@MainActor
final class LLMModelBenchmarkE2ETests: XCTestCase {
    private let runFlag = "DICTKIT_RUN_LLM_E2E_TESTS"
    private let reportDirectoryFlag = "DICTKIT_LLM_E2E_REPORT_DIR"
    private let roundsFlag = "DICTKIT_LLM_E2E_BENCHMARK_ROUNDS"
    private let matrixFlag = "DICTKIT_LLM_E2E_MATRIX"
    private let benchmarkTraceFileName = "debug-trace.jsonl"

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
        let traceFileURL = LLMDebugTraceWriter.defaultFileURL
        try? FileManager.default.removeItem(at: traceFileURL)
        let previousTraceSetting = LLMDebugSettings.isStreamDebugEnabled
        LLMDebugSettings.setStreamDebugEnabled(true)
        defer { LLMDebugSettings.setStreamDebugEnabled(previousTraceSetting) }

        let registry = ModelRegistry()
        let downloadManager = ModelDownloadManager()
        let registryByID = Dictionary(uniqueKeysWithValues: registry.models.map { ($0.id, $0) })
        let selectedModelIDs = matrix.models.map(\.modelId)
        var executedModelIDs: [String] = []
        var skippedModels: [LLMBenchmarkReport.MatrixStatus.SkippedModel] = []
        var modelResults: [LLMBenchmarkReport.ModelResult] = []

        for selection in matrix.models {
            guard let model = registryByID[selection.modelId] else {
                skippedModels.append(.init(modelID: selection.modelId, reason: "missing_from_registry"))
                continue
            }
            guard downloadManager.isDownloaded(model) else {
                skippedModels.append(.init(modelID: selection.modelId, reason: "model_not_downloaded"))
                continue
            }

            executedModelIDs.append(selection.modelId)
            let taskTimeouts = matrix.effectiveTaskTimeouts(forModelID: selection.modelId)
            let service = makeBenchmarkService(requestTimeoutSeconds: taskTimeouts.maximumSeconds)
            service.selectedModelId = selection.modelId
            let tasks: [LLMBenchmarkReport.ModelResult.TaskResult]
            do {
                tasks = try await runBenchmarkTasks(
                    service: service,
                    rounds: rounds,
                    taskTimeouts: taskTimeouts,
                    traceFileURL: traceFileURL
                )
            } catch {
                await service.stopServer()
                throw error
            }
            let summary = summarize(tasks: tasks)

            modelResults.append(
                .init(
                    modelID: model.id,
                    displayName: model.displayName,
                    family: selection.family,
                    variant: selection.variant,
                    quantization: selection.quantization,
                    sizeBytes: model.sizeBytes,
                    contextSize: model.contextSize,
                    status: modelStatus(for: tasks),
                    summary: summary,
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
        try LLMBenchmarkReportWriter().write(
            report: report,
            to: reportDirectoryURL,
            debugTraceFileURL: traceFileURL
        )

        if executedModelIDs.isEmpty {
            throw XCTSkip("No benchmark models are downloaded. Run `just prepare-llm-benchmark-models` first.")
        }
    }

    func testBenchmarkIncludesPronunciationSpellingPreservationCases() {
        let casesByWord = Dictionary(uniqueKeysWithValues: pronunciationCases.map { ($0.word, $0) })
        XCTAssertEqual(casesByWord["corpus"]?.pronunciationGuide, "KOR-pus")
        XCTAssertEqual(casesByWord["corpus"]?.expectedStressSyllables, "COR-pus")
        XCTAssertEqual(casesByWord["cello"]?.pronunciationGuide, "CHEL-oh")
        XCTAssertEqual(casesByWord["cello"]?.expectedStressSyllables, "CEL-lo")
        XCTAssertEqual(casesByWord["xylophone"]?.pronunciationGuide, "ZY-luh-fohn")
        XCTAssertEqual(casesByWord["xylophone"]?.expectedStressSyllables, "XY-lo-phone")
        for testCase in pronunciationCases {
            XCTAssertEqual(
                LLMService.normalizeStressSyllables(
                    testCase.expectedStressSyllables,
                    preservingSpellingOf: testCase.word
                ),
                testCase.expectedStressSyllables
            )
            XCTAssertNil(
                LLMService.normalizeStressSyllables(
                    testCase.pronunciationGuide,
                    preservingSpellingOf: testCase.word
                )
            )
        }
    }

    func testBenchmarkRecallCorpusIncludesCurrentAppPromptRegressionCases() {
        let casesByWord = Dictionary(uniqueKeysWithValues: recallCases.map { ($0.word, $0) })

        XCTAssertEqual(casesByWord["necessary"]?.expectedMode, .fullSpelling)
        XCTAssertEqual(casesByWord["lemmatize"]?.expectedMode, .fullSpelling)
    }

    func testBenchmarkLearningAidsCorpusIncludesCurrentAppAcceptedContextCases() {
        let casesByWord = Dictionary(uniqueKeysWithValues: learningAidsCases.map { ($0.word, $0) })

        XCTAssertEqual(casesByWord["charge"]?.anchor?.text, "charge")
        XCTAssertEqual(casesByWord["charge"]?.anchor?.note, "snapshot only")
        XCTAssertEqual(casesByWord["principal"]?.acceptedPitfalls, ["不要和 principle 混淆"])
    }

    func testBenchmarkAgentEditCorpusExercisesProductPromptToolAndProposalPath() {
        let casesByID = Dictionary(uniqueKeysWithValues: agentEditCases.map { ($0.caseID, $0) })

        let addExample = casesByID["ravenous-add-dictionary-example"]
        XCTAssertEqual(addExample?.word, "ravenous")
        XCTAssertEqual(addExample?.expectedToolName, "propose_example")
        XCTAssertEqual(addExample?.expectedOperations, [.add])
        XCTAssertEqual(addExample?.forbiddenTargetIDs, ["sense-0-0"])
        XCTAssertTrue(addExample?.snapshot.structuredJSON.contains(#""id":"sense-0-0""#) == true)
        XCTAssertTrue(addExample?.snapshot.structuredJSON.contains("to be ravenous") == true)

        let editMnemonics = casesByID["perpetual-delete-two-add-morphology-mnemonic"]
        XCTAssertEqual(editMnemonics?.word, "perpetual")
        XCTAssertEqual(editMnemonics?.expectedToolName, "propose_mnemonic")
        XCTAssertEqual(editMnemonics?.expectedOperations, [.delete, .delete, .add])
        XCTAssertEqual(editMnemonics?.requiredTargetIDs, ["mn-1", "mn-2"])
        XCTAssertTrue(editMnemonics?.snapshot.structuredJSON.contains(#""id":"mn-3""#) == true)
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

    struct PronunciationCase {
        let word: String
        let dialect: String?
        let pronunciationGuide: String?
        let existingIPA: String?
        let senses: [LLMSensePromptInput]
        let expectedStressSyllables: String
        let expectedIPA: String?
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
        let expectedMaskHotspots: [String]
        let requiredFrontContains: [String]
        let requiredFrontExcludes: [String]
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

    struct AgentEditCase {
        let caseID: String
        let word: String
        let userMessage: String
        let snapshot: CardRenderSnapshot
        let expectedToolName: String
        let expectedOperations: [ProposalOperationExpectation]
        let requiredTargetIDs: [String]
        let forbiddenTargetIDs: [String]
    }

    enum ProposalOperationExpectation: String, Equatable {
        case add
        case replace
        case delete
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
            ),
            .init(
                word: "believe",
                senses: [
                    .init(partOfSpeech: "verb", definition: "accept as true or real")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1]
            ),
            .init(
                word: "accommodate",
                senses: [
                    .init(partOfSpeech: "verb", definition: "provide space, lodging, or enough room for"),
                    .init(partOfSpeech: "verb", definition: "fit in with the wishes or needs of")
                ],
                expectedCount: 2,
                requiredSenseCoverage: [1, 2]
            ),
            .init(
                word: "conscientious",
                senses: [
                    .init(partOfSpeech: "adjective", definition: "careful to do everything correctly and responsibly")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1]
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
            ),
            .init(
                word: "believe",
                senses: [
                    .init(partOfSpeech: "verb", definition: "accept as true or real")
                ]
            )
        ]
    }

    var pronunciationCases: [PronunciationCase] {
        [
            .init(
                word: "corpus",
                dialect: "AmE",
                pronunciationGuide: "KOR-pus",
                existingIPA: "kɔrpəs",
                senses: [
                    .init(
                        partOfSpeech: "noun",
                        definition: "a large collection of written or spoken material",
                        semanticHint: "语料库"
                    )
                ],
                expectedStressSyllables: "COR-pus",
                expectedIPA: nil
            ),
            .init(
                word: "cello",
                dialect: "AmE",
                pronunciationGuide: "CHEL-oh",
                existingIPA: "ˈtʃeloʊ",
                senses: [
                    .init(
                        partOfSpeech: "noun",
                        definition: "a large stringed musical instrument",
                        semanticHint: "大提琴"
                    )
                ],
                expectedStressSyllables: "CEL-lo",
                expectedIPA: nil
            ),
            .init(
                word: "xylophone",
                dialect: "AmE",
                pronunciationGuide: "ZY-luh-fohn",
                existingIPA: "ˈzaɪləfoʊn",
                senses: [
                    .init(
                        partOfSpeech: "noun",
                        definition: "a musical instrument with wooden bars struck by mallets",
                        semanticHint: "木琴"
                    )
                ],
                expectedStressSyllables: "XY-lo-phone",
                expectedIPA: nil
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
                expectedMode: .phraseRecall,
                expectedMaskHotspots: [],
                requiredFrontContains: [],
                requiredFrontExcludes: []
            ),
            .init(
                word: "receive",
                senses: [.init(partOfSpeech: "verb", definition: "收到；接收", semanticHint: "收到")],
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"],
                acceptedDefinitionNote: nil,
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedMaskHotspots: ["ei"],
                requiredFrontContains: [],
                requiredFrontExcludes: ["receive"]
            ),
            .init(
                word: "believe",
                senses: [.init(partOfSpeech: "verb", definition: "相信；认为属实", semanticHint: "相信")],
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"],
                acceptedDefinitionNote: "表示相信某件事是真的，或者相信某个人的话",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedMaskHotspots: ["ie"],
                requiredFrontContains: [],
                requiredFrontExcludes: ["believe"]
            ),
            .init(
                word: "accommodate",
                senses: [.init(partOfSpeech: "verb", definition: "容纳；提供住处；满足需要", semanticHint: "容纳；提供住处")],
                acceptedPitfalls: ["双写的 cc 和 mm 容易漏掉", "中间的 o 和 a 顺序容易写乱"],
                acceptedDefinitionNote: "表示提供足够空间、住处，或使安排适应需要",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedMaskHotspots: ["cc", "mm"],
                requiredFrontContains: [],
                requiredFrontExcludes: ["accommodate"]
            ),
            .init(
                word: "conscientious",
                senses: [.init(partOfSpeech: "adjective", definition: "认真负责的；一丝不苟的", semanticHint: "认真负责的")],
                acceptedPitfalls: ["中间的 sci 容易写错", "后半段 tious 容易漏字母或顺序写乱"],
                acceptedDefinitionNote: "表示做事认真、细致，愿意把事情做好",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedMaskHotspots: ["sci", "tio", "ous"],
                requiredFrontContains: [],
                requiredFrontExcludes: ["conscientious"]
            ),
            .init(
                word: "collocation",
                senses: [.init(partOfSpeech: "noun", definition: "固定搭配；常见词语搭配", semanticHint: "常见词语搭配")],
                acceptedPitfalls: ["容易漏掉双写的 ll", "中间元音和后半段顺序容易写错"],
                acceptedDefinitionNote: "指自然的词语搭配，不是任意两个词放在一起",
                acceptedMnemonics: [],
                acceptedCollocations: ["strong collocation"],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedMaskHotspots: ["ll"],
                requiredFrontContains: ["搭配"],
                requiredFrontExcludes: ["collocation"]
            ),
            .init(
                word: "perpetual",
                senses: [.init(partOfSpeech: "adjective", definition: "持续不断的；长期不止的", semanticHint: "持续不断的")],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "常用于表示问题、噪音、争论等持续不止",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .fullSpelling,
                expectedMaskHotspots: [],
                requiredFrontContains: ["持续"],
                requiredFrontExcludes: ["perpetual"]
            ),
            .init(
                word: "necessary",
                senses: [.init(partOfSpeech: "adjective", definition: "必要的；必需的", semanticHint: "必要的")],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "表示某事是必须的，不可避免的",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .fullSpelling,
                expectedMaskHotspots: [],
                requiredFrontContains: ["必要"],
                requiredFrontExcludes: ["necessary"]
            ),
            .init(
                word: "lemmatize",
                senses: [
                    .init(
                        partOfSpeech: "transitive verb",
                        definition: "把…按屈折变化形式归类 bǎ… àn qūzhé biànhuà xíngshì guīlèi"
                    )
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: """
                Lemmatize words to find the basic form of a word — 词语的词根或基本形式
                Find the base form of a word — 找到一个词的原始形态
                """,
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .fullSpelling,
                expectedMaskHotspots: [],
                requiredFrontContains: [],
                requiredFrontExcludes: ["屈折", "qūzhé", "biànhuà", "lemmatize"]
            )
        ]
    }

    var learningAidsCases: [LearningAidsCase] {
        [
            .init(
                word: "charge",
                senses: [
                    .init(partOfSpeech: "noun", definition: "formal accusation"),
                    .init(partOfSpeech: "verb", definition: "ask someone to pay a price")
                ],
                acceptedPitfalls: ["容易和负责、收费几个义项混在一起"],
                acceptedDefinitionNote: "表示收费时是让别人支付一笔钱",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: LLMAnchorSnapshot(text: "charge", note: "snapshot only")
            ),
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
                word: "demolish",
                senses: [
                    .init(partOfSpeech: "verb", definition: "to knock down and destroy a building or structure")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "常指建筑或结构被拆毁",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            )
        ]
    }

    var agentEditCases: [AgentEditCase] {
        [
            .init(
                caseID: "ravenous-add-dictionary-example",
                word: "ravenous",
                userMessage: "把字典里的 to be ravenous 饿极了 加到例子里",
                snapshot: CardRenderSnapshot(
                    kind: .standard,
                    word: "ravenous",
                    phonetic: "/ˈræv.ən.əs/",
                    wireframe: "ravenous\nadjective: extremely hungry\nto be ravenous 饿极了",
                    structuredJSON: """
                    {"artifacts":{"collocations":[],"examples":[],"mnemonics":[],"pitfalls":[]},"kind":"standard","phonetic":"/ˈræv.ən.əs/","senses":[{"definition":"extremely hungry","examples":["to be ravenous 饿极了"],"id":"sense-0-0","pos":"adjective"}],"word":"ravenous"}
                    """,
                    aiSectionOrder: []
                ),
                expectedToolName: "propose_example",
                expectedOperations: [.add],
                requiredTargetIDs: [],
                forbiddenTargetIDs: ["sense-0-0"]
            ),
            .init(
                caseID: "perpetual-delete-two-add-morphology-mnemonic",
                word: "perpetual",
                userMessage: "删掉第一第二个记忆点，保留第三个，再加一个构词法角度的新增记忆点",
                snapshot: CardRenderSnapshot(
                    kind: .standard,
                    word: "perpetual",
                    phonetic: "/pərˈpetʃ.u.əl/",
                    wireframe: """
                    perpetual
                    Mnemonics
                    [mn-1] Perpetual = Repeat!
                    [mn-2] Perpetual = Never End!
                    [mn-3] per-PET-u-al, e 发短音 /e/
                    """,
                    structuredJSON: """
                    {"artifacts":{"collocations":[],"examples":[],"mnemonics":[{"id":"mn-1","text":"Perpetual = Repeat!"},{"id":"mn-2","text":"Perpetual = Never End!"},{"id":"mn-3","text":"per-PET-u-al, e 发短音 /e/"}],"pitfalls":[]},"kind":"standard","phonetic":"/pərˈpetʃ.u.əl/","senses":[{"definition":"continuing forever or for a very long time","examples":[],"id":"sense-0-0","pos":"adjective"}],"word":"perpetual"}
                    """,
                    aiSectionOrder: [.mnemonics]
                ),
                expectedToolName: "propose_mnemonic",
                expectedOperations: [.delete, .delete, .add],
                requiredTargetIDs: ["mn-1", "mn-2"],
                forbiddenTargetIDs: ["mn-3", "mnemonics", "perpetual"]
            )
        ]
    }

    func runBenchmarkTasks(
        service: LLMService,
        rounds: Int,
        taskTimeouts: LLMBenchmarkTaskTimeouts,
        traceFileURL: URL
    ) async throws -> [LLMBenchmarkReport.ModelResult.TaskResult] {
        var tasks: [LLMBenchmarkReport.ModelResult.TaskResult] = []
        for _ in 0..<rounds {
            for testCase in exampleCases {
                tasks.append(
                    await runExampleTask(
                        service: service,
                        testCase: testCase,
                        timeoutSeconds: taskTimeouts.seconds(for: "example_sentences"),
                        traceFileURL: traceFileURL
                    )
                )
            }
            for testCase in usageCases {
                tasks.append(
                    await runUsageTask(
                        service: service,
                        testCase: testCase,
                        timeoutSeconds: taskTimeouts.seconds(for: "usage_hints"),
                        traceFileURL: traceFileURL
                    )
                )
            }
            for testCase in pronunciationCases {
                tasks.append(
                    await runPronunciationTask(
                        service: service,
                        testCase: testCase,
                        timeoutSeconds: taskTimeouts.seconds(for: "pronunciation_enhancement"),
                        traceFileURL: traceFileURL
                    )
                )
            }
            for testCase in recallCases {
                tasks.append(
                    await runRecallTask(
                        service: service,
                        testCase: testCase,
                        timeoutSeconds: taskTimeouts.seconds(for: "recall_draft_decision"),
                        traceFileURL: traceFileURL
                    )
                )
            }
            for testCase in learningAidsCases {
                tasks.append(
                    await runLearningAidsTask(
                        service: service,
                        testCase: testCase,
                        timeoutSeconds: taskTimeouts.seconds(for: "learning_aids"),
                        traceFileURL: traceFileURL
                    )
                )
            }
            for testCase in agentEditCases {
                tasks.append(
                    await runAgentEditTask(
                        service: service,
                        testCase: testCase,
                        timeoutSeconds: taskTimeouts.seconds(for: "agent_edit_proposal"),
                        traceFileURL: traceFileURL
                    )
                )
            }
        }
        return tasks
    }

    func runExampleTask(
        service: LLMService,
        testCase: ExampleCase,
        timeoutSeconds: Int,
        traceFileURL: URL
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(
            taskType: "example_sentences",
            caseID: testCase.word,
            word: testCase.word,
            timeoutSeconds: timeoutSeconds,
            traceFileURL: traceFileURL
        ) {
            let examples = try await service.generateExampleSentenceArtifacts(
                word: testCase.word,
                senses: testCase.senses
            )
            var qualityIssues: [String] = []
            let coveredSenseIndexes = Set(examples.compactMap(\.senseIndex))
            if examples.count != testCase.expectedCount {
                qualityIssues.append("expected_count_mismatch")
            }
            if Set(examples.map(\.english)).count != examples.count {
                qualityIssues.append("duplicate_examples")
            }
            if !testCase.requiredSenseCoverage.isSubset(of: coveredSenseIndexes) {
                qualityIssues.append("missing_sense_coverage")
            }
            if !examples.allSatisfy({ self.isPlainText($0.english) && self.isPlainText($0.translation) }) {
                qualityIssues.append("formatting_noise")
            }
            let duplicateRate = examples.isEmpty ? 0.0 : Double(examples.count - Set(examples.map(\.english)).count) / Double(examples.count)
            return .init(
                qualityIssues: qualityIssues,
                warnings: [],
                metrics: [
                    "expected_count": .int(testCase.expectedCount),
                    "actual_count": .int(examples.count),
                    "sense_coverage": .double(Double(coveredSenseIndexes.count) / Double(max(1, testCase.requiredSenseCoverage.count))),
                    "duplicate_rate": .double(duplicateRate),
                    "timeout_seconds": .int(timeoutSeconds)
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
        testCase: UsageCase,
        timeoutSeconds: Int,
        traceFileURL: URL
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(
            taskType: "usage_hints",
            caseID: testCase.word,
            word: testCase.word,
            timeoutSeconds: timeoutSeconds,
            traceFileURL: traceFileURL
        ) {
            let hint = try await service.generateUsageHintText(
                word: testCase.word,
                senses: testCase.senses
            )
            let lines = self.normalizedNonEmptyLines(from: hint)
            let evaluation = LLMBenchmarkUsageEvaluation.assess(
                lines: lines,
                expectedCount: LLMBenchmarkUsageEvaluation.expectedLineCount(for: testCase.senses),
                isPlainBilingualLine: self.isPlainBilingualLine(_:)
            )
            return .init(
                qualityIssues: evaluation.qualityIssues,
                warnings: evaluation.warnings,
                metrics: evaluation.metrics,
                output: evaluation.output
            )
        }
    }

    func runPronunciationTask(
        service: LLMService,
        testCase: PronunciationCase,
        timeoutSeconds: Int,
        traceFileURL: URL
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(
            taskType: "pronunciation_enhancement",
            caseID: testCase.word,
            word: testCase.word,
            timeoutSeconds: timeoutSeconds,
            traceFileURL: traceFileURL
        ) {
            let enhancement = try await service.generatePronunciationEnhancement(
                word: testCase.word,
                dialect: testCase.dialect,
                pronunciationGuide: testCase.pronunciationGuide,
                existingIPA: testCase.existingIPA,
                senses: testCase.senses
            )

            var qualityIssues: [String] = []
            let stressMatchesExpected = enhancement.stressSyllables == testCase.expectedStressSyllables
            if !stressMatchesExpected {
                qualityIssues.append("stress_syllables_mismatch")
            }

            let ipaMatchesExpected: Bool?
            if let expectedIPA = testCase.expectedIPA {
                ipaMatchesExpected = enhancement.ipa == expectedIPA
                if ipaMatchesExpected == false {
                    qualityIssues.append("ipa_mismatch")
                }
            } else {
                ipaMatchesExpected = nil
            }

            return .init(
                qualityIssues: qualityIssues,
                warnings: [],
                metrics: [
                    "stress_matches_expected": .bool(stressMatchesExpected),
                    "ipa_matches_expected": ipaMatchesExpected.map(JSONValue.bool) ?? .null,
                    "timeout_seconds": .int(timeoutSeconds)
                ],
                output: [
                    "stress_syllables": .string(enhancement.stressSyllables),
                    "expected_stress_syllables": .string(testCase.expectedStressSyllables),
                    "ipa": enhancement.ipa.map(JSONValue.string) ?? .null,
                    "expected_ipa": testCase.expectedIPA.map(JSONValue.string) ?? .null,
                    "pronunciation_guide": testCase.pronunciationGuide.map(JSONValue.string) ?? .null
                ]
            )
        }
    }

    func runRecallTask(
        service: LLMService,
        testCase: RecallCase,
        timeoutSeconds: Int,
        traceFileURL: URL
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(
            taskType: "recall_draft_decision",
            caseID: testCase.word,
            word: testCase.word,
            timeoutSeconds: timeoutSeconds,
            traceFileURL: traceFileURL
        ) {
            let context = self.appRecallGenerationContext(for: testCase)
            let allowedModes = self.appRecommendedRecallAllowedModes(for: testCase)
            let modePrior = self.appRecommendedRecallModePrior(for: testCase)
            let decision = try await service.generateRecallCardDraftDecision(
                word: testCase.word,
                senses: testCase.senses,
                context: context,
                allowedModes: allowedModes,
                modePrior: modePrior,
                anchor: testCase.previewAnchor
            )

            var qualityIssues: [String] = []
            if decision.draft.front.isEmpty || decision.draft.back.isEmpty {
                qualityIssues.append("empty_card_side")
            }
            if decision.draft.back != testCase.word {
                qualityIssues.append("back_side_changed")
            }
            if !allowedModes.contains(decision.draft.mode) {
                qualityIssues.append("disallowed_mode")
            }
            if !self.isPlainText(decision.draft.front) || !self.isPlainText(decision.draft.back) {
                qualityIssues.append("formatting_noise")
            }
            if decision.draft.front.containsPinyinDiacritics || (decision.draft.hint?.containsPinyinDiacritics ?? false) {
                qualityIssues.append("romanization_leak")
            }
            if self.cuePlanContainsTarget(decision.draft.front, target: testCase.word) {
                qualityIssues.append("target_leak")
            }
            if !testCase.requiredFrontContains.allSatisfy(decision.draft.front.contains) {
                qualityIssues.append("missing_expected_cue")
            }
            if testCase.requiredFrontExcludes.contains(where: decision.draft.front.contains) {
                qualityIssues.append("front_contains_forbidden_fragment")
            }
            if decision.draft.mode == .targetedLetterCloze {
                if self.underscoreGroupCount(in: decision.draft.front) != 1 {
                    qualityIssues.append("invalid_cloze_shape")
                }
                let gapLength = self.longestUnderscoreRun(in: decision.draft.front)
                if !(2...3).contains(gapLength) {
                    qualityIssues.append("invalid_cloze_gap_length")
                }
                if !decision.draft.front.containsHanScript {
                    qualityIssues.append("missing_chinese_cue")
                }
                if !testCase.expectedMaskHotspots.isEmpty {
                    let hiddenText = decision.maskPlan?.hiddenText.lowercased() ?? ""
                    let matchesExpectedHotspot = testCase.expectedMaskHotspots.contains {
                        hiddenText.contains($0.lowercased())
                    }
                    if !matchesExpectedHotspot {
                        qualityIssues.append("mask_plan_missed_expected_hotspot")
                    }
                }
            }
            if decision.draft.mode != testCase.expectedMode {
                qualityIssues.append("mode_differs_from_baseline")
            }

            var metrics: [String: JSONValue] = [
                "mode": .string(decision.draft.mode.rawValue),
                "expected_mode": .string(testCase.expectedMode.rawValue),
                "front_clean": .bool(self.isPlainText(decision.draft.front)),
                "target_leak": .bool(self.cuePlanContainsTarget(decision.draft.front, target: testCase.word)),
                "timeout_seconds": .int(timeoutSeconds)
            ]
            if decision.draft.mode == .targetedLetterCloze {
                metrics["mask_plan_start_index"] = decision.maskPlan.map { .int($0.startIndex) } ?? .null
                metrics["mask_plan_hidden_text"] = decision.maskPlan.map { .string($0.hiddenText) } ?? .null
                metrics["mask_plan_repaired"] = .bool(decision.maskPlanRepaired)
                metrics["mask_plan_fallback"] = .bool(decision.maskPlanFallback)
                metrics["expected_mask_hotspots"] = .string(testCase.expectedMaskHotspots.joined(separator: ","))
            }

            return .init(
                qualityIssues: qualityIssues,
                warnings: [],
                metrics: metrics,
                output: [
                    "front": .string(decision.draft.front),
                    "back": .string(decision.draft.back),
                    "hint": decision.draft.hint.map(JSONValue.string) ?? .null,
                    "selection_reason": .string(decision.selectionReason?.primaryGoal ?? ""),
                    "cue_plan": .string(decision.cuePlan?.normalizedCue ?? ""),
                    "mask_plan_reason": decision.maskPlan.map { .string($0.teachingReason) } ?? .null
                ]
            )
        }
    }

    func runLearningAidsTask(
        service: LLMService,
        testCase: LearningAidsCase,
        timeoutSeconds: Int,
        traceFileURL: URL
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(
            taskType: "learning_aids",
            caseID: testCase.word,
            word: testCase.word,
            timeoutSeconds: timeoutSeconds,
            traceFileURL: traceFileURL
        ) {
            let ranked = try await service.generateRankedLearningAids(
                word: testCase.word,
                senses: testCase.senses,
                acceptedContext: self.appLearningAidAcceptedContext(for: testCase),
                anchor: testCase.anchor
            )
            let aids = ranked.aids
            var qualityIssues: [String] = []
            if !self.isLearningAidResultWellFormed(ranked) {
                qualityIssues.append("invalid_section_selection")
            }
            if !aids.pitfalls.allSatisfy({ self.isPlainText($0.summary) && !self.startsWithListMarker($0.summary) }) {
                qualityIssues.append("pitfall_formatting_noise")
            }
            if !aids.mnemonics.allSatisfy({ self.isPlainText($0.clue) && $0.clue.count <= 80 }) {
                qualityIssues.append("mnemonic_formatting_noise")
            }
            if !aids.collocations.allSatisfy({
                self.isPlainText($0.phrase)
                    && !$0.phrase.contains("\n")
                    && !$0.phrase.hasSuffix(".")
                    && !$0.phrase.hasSuffix("!")
                    && !$0.phrase.hasSuffix("?")
            }) {
                qualityIssues.append("collocation_formatting_noise")
            }

            let overlapScores = [
                ranked.selections.pitfalls.flatMap { self.sectionSummary(selection: $0, textByID: Dictionary(uniqueKeysWithValues: aids.pitfalls.map { ($0.id, $0.summary) }), senses: testCase.senses) },
                ranked.selections.mnemonics.flatMap { self.sectionSummary(selection: $0, textByID: Dictionary(uniqueKeysWithValues: aids.mnemonics.map { ($0.id, $0.clue) }), senses: testCase.senses) },
                ranked.selections.collocations.flatMap { self.sectionSummary(selection: $0, textByID: Dictionary(uniqueKeysWithValues: aids.collocations.map { ($0.id, $0.phrase) }), senses: testCase.senses) }
            ].compactMap { $0?.overlap }

            let averageOverlap = overlapScores.isEmpty ? 0.0 : overlapScores.reduce(0, +) / Double(overlapScores.count)
            if averageOverlap > 0.5 {
                qualityIssues.append("high_definition_overlap")
            }

            return .init(
                qualityIssues: qualityIssues,
                warnings: [],
                metrics: [
                    "pitfalls_count": .int(aids.pitfalls.count),
                    "mnemonics_count": .int(aids.mnemonics.count),
                    "collocations_count": .int(aids.collocations.count),
                    "definition_overlap": .double(averageOverlap),
                    "selection_complete": .bool(self.isLearningAidResultWellFormed(ranked)),
                    "timeout_seconds": .int(timeoutSeconds)
                ],
                output: [
                    "pitfall": .string(self.sectionSummary(selection: ranked.selections.pitfalls, textByID: Dictionary(uniqueKeysWithValues: aids.pitfalls.map { ($0.id, $0.summary) }), senses: testCase.senses)?.text ?? ""),
                    "mnemonic": .string(self.sectionSummary(selection: ranked.selections.mnemonics, textByID: Dictionary(uniqueKeysWithValues: aids.mnemonics.map { ($0.id, $0.clue) }), senses: testCase.senses)?.text ?? ""),
                    "collocation": .string(self.sectionSummary(selection: ranked.selections.collocations, textByID: Dictionary(uniqueKeysWithValues: aids.collocations.map { ($0.id, $0.phrase) }), senses: testCase.senses)?.text ?? "")
                ]
            )
        }
    }

    func runAgentEditTask(
        service: LLMService,
        testCase: AgentEditCase,
        timeoutSeconds: Int,
        traceFileURL: URL
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        await measureTask(
            taskType: "agent_edit_proposal",
            caseID: testCase.caseID,
            word: testCase.word,
            timeoutSeconds: timeoutSeconds,
            traceFileURL: traceFileURL
        ) {
            let persistence = BenchmarkAgentPersistence()
            let wordID = UUID()
            let session = AgentSession(
                wordID: wordID,
                persistence: persistence,
                snapshotProvider: BenchmarkAgentSnapshotProvider(snapshot: testCase.snapshot),
                generator: BenchmarkAgentGenerator(service: service)
            )

            try session.reload()
            try await session.sendUserMessage(testCase.userMessage)

            let toolCalls = session.messages.compactMap { message -> (String, String)? in
                guard case .toolCall(let name, let argsJSON) = message.content else { return nil }
                return (name, argsJSON)
            }
            let proposals = session.messages.compactMap { message -> ProposalRecord? in
                guard case .actionProposal(let proposal) = message.content else { return nil }
                return proposal
            }
            let operations = proposals.map { self.operationExpectation(from: $0.operation) }
            let targetIDs = proposals.compactMap { self.targetID(from: $0.operation) }
            let proposalToolCalls = toolCalls.filter { $0.0.hasPrefix("propose_") }

            var qualityIssues: [String] = []
            if proposalToolCalls.isEmpty {
                qualityIssues.append("missing_proposal_tool_call")
            }
            if proposalToolCalls.contains(where: { $0.0 != testCase.expectedToolName }) {
                qualityIssues.append("wrong_proposal_tool")
            }
            if operations != testCase.expectedOperations {
                qualityIssues.append("operation_sequence_mismatch")
            }
            if !testCase.requiredTargetIDs.allSatisfy(targetIDs.contains) {
                qualityIssues.append("missing_required_target_id")
            }
            if testCase.forbiddenTargetIDs.contains(where: targetIDs.contains) {
                qualityIssues.append("forbidden_target_id_used")
            }
            if proposals.count != testCase.expectedOperations.count {
                qualityIssues.append("proposal_count_mismatch")
            }

            return .init(
                qualityIssues: qualityIssues,
                warnings: [],
                metrics: [
                    "proposal_count": .int(proposals.count),
                    "proposal_tool_call_count": .int(proposalToolCalls.count),
                    "target_id_count": .int(targetIDs.count),
                    "timeout_seconds": .int(timeoutSeconds)
                ],
                output: [
                    "user_message": .string(testCase.userMessage),
                    "tool_calls": .array(
                        toolCalls.map { name, argsJSON in
                            .object([
                                "name": .string(name),
                                "args": .string(argsJSON)
                            ])
                        }
                    ),
                    "proposals": .array(
                        proposals.map { proposal in
                            .object([
                                "kind": .string(proposal.kind.rawValue),
                                "operation": .string(self.operationExpectation(from: proposal.operation).rawValue),
                                "target_id": self.targetID(from: proposal.operation).map(JSONValue.string) ?? .null,
                                "diff_summary": .string(proposal.diffSummary),
                                "payload": .string(proposal.payloadJSON)
                            ])
                        }
                    )
                ]
            )
        }
    }

    func measureTask(
        taskType: String,
        caseID: String,
        word: String,
        timeoutSeconds: Int,
        traceFileURL: URL,
        operation: @escaping @MainActor () async throws -> MeasuredTaskOutcome
    ) async -> LLMBenchmarkReport.ModelResult.TaskResult {
        let clock = ContinuousClock()
        let start = clock.now
        let traceEventStartIndex = traceEventCount(in: traceFileURL)
        do {
            let outcome = try await withTaskTimeout(seconds: timeoutSeconds, operation: operation)
            let elapsed = start.duration(to: clock.now)
            let traceSessionIDs = traceSessionIDs(in: traceFileURL, startingAt: traceEventStartIndex)
            return .init(
                taskType: taskType,
                caseID: caseID,
                word: word,
                status: outcome.status,
                latencyMilliseconds: elapsed.milliseconds,
                hardFailures: [],
                qualityIssues: outcome.qualityIssues,
                warnings: outcome.warnings,
                metrics: mergedMetrics(outcome.metrics, timeoutSeconds: timeoutSeconds),
                output: outcome.output,
                traceFile: benchmarkTraceFileName,
                traceSessionIDs: traceSessionIDs
            )
        } catch {
            let elapsed = start.duration(to: clock.now)
            let traceSessionIDs = traceSessionIDs(in: traceFileURL, startingAt: traceEventStartIndex)
            if let qualityIssues = LLMBenchmarkErrorEvaluation.qualityIssues(from: error) {
                return .init(
                    taskType: taskType,
                    caseID: caseID,
                    word: word,
                    status: .passedWithIssues,
                    latencyMilliseconds: elapsed.milliseconds,
                    hardFailures: [],
                    qualityIssues: qualityIssues,
                    warnings: [],
                    metrics: ["timeout_seconds": .int(timeoutSeconds)],
                    output: ["quality_failure": .string(String(reflecting: error))],
                    traceFile: benchmarkTraceFileName,
                    traceSessionIDs: traceSessionIDs
                )
            }
            return .init(
                taskType: taskType,
                caseID: caseID,
                word: word,
                status: .failed,
                latencyMilliseconds: elapsed.milliseconds,
                hardFailures: executionFailures(from: error),
                qualityIssues: [],
                warnings: [],
                metrics: ["timeout_seconds": .int(timeoutSeconds)],
                output: [:],
                traceFile: benchmarkTraceFileName,
                traceSessionIDs: traceSessionIDs
            )
        }
    }

    struct MeasuredTaskOutcome {
        let qualityIssues: [String]
        let warnings: [String]
        let metrics: [String: JSONValue]
        let output: [String: JSONValue]

        var status: LLMBenchmarkReport.ModelResult.Status {
            qualityIssues.isEmpty ? .passed : .passedWithIssues
        }
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

    func appRecallGenerationContext(for testCase: RecallCase) -> LLMRecallGenerationContext {
        LLMService.normalizeRecallGenerationContext(
            LLMRecallGenerationContext(
                acceptedPitfalls: testCase.acceptedPitfalls,
                acceptedUsageHints: acceptedUsageHints(from: testCase.acceptedDefinitionNote),
                acceptedMnemonics: testCase.acceptedMnemonics,
                acceptedCollocations: testCase.acceptedCollocations
            )
        )
    }

    func appRecommendedRecallAllowedModes(for testCase: RecallCase) -> [LLMRecallCardMode] {
        LLMService.recommendedRecallAllowedModes(
            for: testCase.word,
            context: appRecallGenerationContext(for: testCase)
        )
    }

    func appRecommendedRecallModePrior(for testCase: RecallCase) -> LLMRecallCardMode? {
        LLMService.recommendedRecallModePrior(
            for: testCase.word,
            context: appRecallGenerationContext(for: testCase),
            allowedModes: appRecommendedRecallAllowedModes(for: testCase)
        )
    }

    func appLearningAidAcceptedContext(for testCase: LearningAidsCase) -> LLMLearningAidAcceptedContext {
        LLMLearningAidAcceptedContext(
            acceptedPitfalls: testCase.acceptedPitfalls,
            acceptedUsageHints: testCase.acceptedDefinitionNote.map { [$0] } ?? [],
            acceptedMnemonics: testCase.acceptedMnemonics,
            acceptedCollocations: testCase.acceptedCollocations
        )
    }

    func operationExpectation(from operation: ProposalRecord.Operation) -> ProposalOperationExpectation {
        switch operation {
        case .add:
            return .add
        case .replace:
            return .replace
        case .delete:
            return .delete
        }
    }

    func targetID(from operation: ProposalRecord.Operation) -> String? {
        switch operation {
        case .add:
            return nil
        case .replace(let targetID), .delete(let targetID):
            return targetID
        }
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

    func makeBenchmarkService(requestTimeoutSeconds: Int) -> LLMService {
        let defaults = UserDefaults(suiteName: "LLMModelBenchmarkE2ETests-\(UUID().uuidString)") ?? .standard
        return LLMService(
            defaults: defaults,
            rpcClientConfiguration: .init(requestTimeoutSeconds: TimeInterval(requestTimeoutSeconds))
        )
    }

    func summarize(tasks: [LLMBenchmarkReport.ModelResult.TaskResult]) -> LLMBenchmarkReport.ModelResult.Summary {
        let totalTasks = tasks.count
        let failedTasks = tasks.filter { $0.status == .failed }.count
        let issueTasks = tasks.filter { $0.status == .passedWithIssues }.count
        let cleanPassedTasks = tasks.filter { $0.status == .passed }.count
        let executionPassedTasks = cleanPassedTasks + issueTasks
        let warningCount = tasks.reduce(0) { $0 + $1.warnings.count }
        let totalLatency = tasks.reduce(0) { $0 + $1.latencyMilliseconds }
        let averageLatency = totalTasks == 0 ? 0 : totalLatency / totalTasks
        let executionPassRate = totalTasks == 0 ? 0.0 : Double(executionPassedTasks) / Double(totalTasks)
        let cleanPassRate = totalTasks == 0 ? 0.0 : Double(cleanPassedTasks) / Double(totalTasks)
        return .init(
            totalTasks: totalTasks,
            executionPassedTasks: executionPassedTasks,
            cleanPassedTasks: cleanPassedTasks,
            issueTasks: issueTasks,
            failedTasks: failedTasks,
            warningCount: warningCount,
            totalLatencyMilliseconds: totalLatency,
            averageLatencyMilliseconds: averageLatency,
            executionPassRate: executionPassRate,
            cleanPassRate: cleanPassRate
        )
    }

    func modelStatus(for tasks: [LLMBenchmarkReport.ModelResult.TaskResult]) -> LLMBenchmarkReport.ModelResult.Status {
        if tasks.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if tasks.contains(where: { $0.status == .passedWithIssues }) {
            return .passedWithIssues
        }
        return .passed
    }

    func mergedMetrics(_ metrics: [String: JSONValue], timeoutSeconds: Int) -> [String: JSONValue] {
        var merged = metrics
        merged["timeout_seconds"] = .int(timeoutSeconds)
        return merged
    }

    func executionFailures(from error: Error) -> [String] {
        if error is BenchmarkTimeoutError {
            return ["benchmark_timeout"]
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return ["rpc_timeout"]
        }
        let reflected = String(reflecting: error)
        if reflected.localizedCaseInsensitiveContains("timed out") {
            return ["rpc_timeout: \(reflected)"]
        }
        return [reflected]
    }

    func withTaskTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { @MainActor in
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BenchmarkTimeoutError(seconds: seconds)
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    func traceEventCount(in fileURL: URL) -> Int {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return 0
        }
        return content.split(whereSeparator: \.isNewline).count
    }

    func traceSessionIDs(in fileURL: URL, startingAt startIndex: Int) -> [String] {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        let ids = content
            .split(whereSeparator: \.isNewline)
            .dropFirst(startIndex)
            .compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let event = try? decoder.decode(LLMDebugTraceWriter.Event.self, from: data) else {
                    return nil
                }
                return event.id
            }
        return Array(Set(ids)).sorted()
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

private struct BenchmarkTimeoutError: Error, CustomStringConvertible {
    let seconds: Int

    var description: String {
        "BenchmarkTimeoutError(seconds: \(seconds))"
    }
}

private struct BenchmarkAgentSnapshotProvider: AgentCardSnapshotProviding {
    let snapshot: CardRenderSnapshot

    func snapshot(for wordID: UUID) throws -> CardRenderSnapshot {
        snapshot
    }
}

private struct BenchmarkAgentGenerator: AgentGenerating {
    let service: LLMService

    func generate(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]
    ) async throws -> GenerateResult {
        try await service.generate(
            messages: messages,
            tools: tools,
            parallelToolCalls: false
        )
    }

    func generateStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition],
        onDelta: @escaping @Sendable (String) -> Void,
        onReasoningDelta: @escaping @Sendable (String) -> Void
    ) async throws -> GenerateResult {
        try await service.generateStreaming(
            messages: messages,
            tools: tools,
            parallelToolCalls: false,
            onDelta: onDelta,
            onReasoningDelta: onReasoningDelta
        )
    }
}

private final class BenchmarkAgentPersistence: AgentSessionPersisting {
    private var sessionsByWordID: [UUID: AgentChatSession] = [:]
    private var messagesBySessionID: [UUID: [AgentChatMessage]] = [:]

    func upsertSession(for wordID: UUID, preferences: AgentSessionPreferences) throws -> AgentChatSession {
        if var existing = sessionsByWordID[wordID] {
            existing.preferences = preferences
            existing.updatedAt = Date()
            sessionsByWordID[wordID] = existing
            return existing
        }
        let session = AgentChatSession(wordItemID: wordID, preferences: preferences)
        sessionsByWordID[wordID] = session
        messagesBySessionID[session.id] = []
        return session
    }

    func session(for wordID: UUID) throws -> AgentChatSession? {
        sessionsByWordID[wordID]
    }

    func loadMessages(sessionID: UUID) throws -> [AgentChatMessage] {
        messagesBySessionID[sessionID] ?? []
    }

    func addMessage(
        sessionID: UUID,
        role: AgentChatMessage.Role,
        status: AgentChatMessage.Status,
        content: MessageContent,
        createdAt: Date,
        supersededBy: UUID?,
        interrupted: Bool
    ) throws -> AgentChatMessage {
        let ordinal = messagesBySessionID[sessionID, default: []].count
        let message = AgentChatMessage(
            sessionID: sessionID,
            ordinal: ordinal,
            role: role,
            createdAt: createdAt,
            status: status,
            content: content,
            supersededBy: supersededBy,
            interrupted: interrupted
        )
        messagesBySessionID[sessionID, default: []].append(message)
        return message
    }

    func deleteMessages(ids: [UUID]) throws {
        let idSet = Set(ids)
        for sessionID in messagesBySessionID.keys {
            messagesBySessionID[sessionID]?.removeAll { idSet.contains($0.id) }
        }
    }

    func clearMessages(sessionID: UUID) throws {
        messagesBySessionID[sessionID] = []
    }

    func resetSession(for wordID: UUID) throws {
        guard let session = sessionsByWordID.removeValue(forKey: wordID) else { return }
        messagesBySessionID.removeValue(forKey: session.id)
    }

    func updateProposal(messageID: UUID, proposal: ProposalRecord) throws -> AgentChatMessage {
        for sessionID in messagesBySessionID.keys {
            guard let index = messagesBySessionID[sessionID]?.firstIndex(where: { $0.id == messageID }) else {
                continue
            }
            messagesBySessionID[sessionID]?[index].content = .actionProposal(proposal)
            return messagesBySessionID[sessionID]![index]
        }
        throw AgentSessionError.sessionUnavailable
    }
}

private extension String {
    var containsHanScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF:
                return true
            default:
                return false
            }
        }
    }

    var containsPinyinDiacritics: Bool {
        range(
            of: #"[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜĀÁǍÀĒÉĚÈĪÍǏÌŌÓǑÒŪÚǓÙǕǗǙǛ]"#,
            options: .regularExpression
        ) != nil
    }
}
