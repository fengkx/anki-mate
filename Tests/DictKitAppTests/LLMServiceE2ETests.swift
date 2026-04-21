import XCTest
@testable import AnkiMateLLM

@MainActor
final class LLMServiceE2ETests: XCTestCase {
    private let runFlag = "DICTKIT_RUN_LLM_E2E_TESTS"
    private let baselineFlag = "DICTKIT_RUN_LLM_E2E_BASELINE_TESTS"
    private let modelFlag = "DICTKIT_LLM_E2E_MODEL_ID"

    func testSmokeExampleGenerationUsesFixedMultiSenseCorpusWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "smoke")
        defer { Task { await service.stopServer() } }
        let testCase = ExampleSmokeCase(
            word: "light",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "illumination"),
                LLMSensePromptInput(partOfSpeech: "adjective", definition: "not heavy"),
                LLMSensePromptInput(partOfSpeech: "verb", definition: "ignite")
            ]
        )

        let sentences = try await service.generateExampleSentences(
            word: testCase.word,
            senses: testCase.senses
        )

        XCTAssertEqual(
            sentences.count,
            testCase.senses.count,
            failureContext(
                suite: "smoke",
                promptFamily: "example_sentences",
                word: testCase.word,
                modelId: service.selectedModelId,
                issue: "expected \(testCase.senses.count) lines, got \(sentences.count)"
            )
        )
        XCTAssertEqual(
            Set(sentences).count,
            sentences.count,
            failureContext(
                suite: "smoke",
                promptFamily: "example_sentences",
                word: testCase.word,
                modelId: service.selectedModelId,
                issue: "duplicate example lines detected"
            )
        )
        XCTAssertTrue(
            sentences.allSatisfy { isPlainBilingualLine($0) },
            failureContext(
                suite: "smoke",
                promptFamily: "example_sentences",
                word: testCase.word,
                modelId: service.selectedModelId,
                issue: "expected plain bilingual lines without markdown noise"
            )
        )
    }

    func testSmokeUsageHintUsesFixedCorpusWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "smoke")
        defer { Task { await service.stopServer() } }
        let testCase = UsageSmokeCase(
            word: "charge",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price"),
                LLMSensePromptInput(partOfSpeech: "verb", definition: "fill a battery")
            ]
        )

        let hint = try await service.optimizeDefinition(
            word: testCase.word,
            senses: testCase.senses
        )
        let lines = normalizedNonEmptyLines(from: hint)

        XCTAssertEqual(
            lines.count,
            testCase.senses.count,
            failureContext(
                suite: "smoke",
                promptFamily: "usage_hints",
                word: testCase.word,
                modelId: service.selectedModelId,
                issue: "expected \(testCase.senses.count) usage lines, got \(lines.count)"
            )
        )
        XCTAssertTrue(
            lines.allSatisfy { isPlainBilingualLine($0) },
            failureContext(
                suite: "smoke",
                promptFamily: "usage_hints",
                word: testCase.word,
                modelId: service.selectedModelId,
                issue: "expected clean bilingual usage lines"
            )
        )
    }

    func testBaselineExampleSentenceArtifactsMeetFixedCorpusContractWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "baseline", requireBaseline: true)
        defer { Task { await service.stopServer() } }

        for testCase in exampleBaselineCorpus {
            let examples = try await service.generateExampleSentenceArtifacts(
                word: testCase.word,
                senses: testCase.senses
            )
            let context = failureContext(
                suite: "baseline",
                promptFamily: "example_sentence_artifacts",
                word: testCase.word,
                modelId: service.selectedModelId
            )

            XCTAssertEqual(
                examples.count,
                testCase.expectedCount,
                "\(context) issue=expected \(testCase.expectedCount) examples, got \(examples.count)"
            )
            XCTAssertEqual(
                Set(examples.map(\.english)).count,
                examples.count,
                "\(context) issue=duplicate english examples detected"
            )
            XCTAssertTrue(
                examples.allSatisfy { !$0.english.isEmpty && !$0.translation.isEmpty },
                "\(context) issue=empty english or translation field"
            )
            XCTAssertTrue(
                examples.allSatisfy { isPlainText($0.english) && isPlainText($0.translation) },
                "\(context) issue=markdown or labeled formatting leaked into structured example output"
            )

            let coveredSenseIndexes = Set(examples.compactMap(\.senseIndex))
            XCTAssertTrue(
                testCase.requiredSenseCoverage.isSubset(of: coveredSenseIndexes),
                "\(context) issue=missing sense coverage expected=\(Array(testCase.requiredSenseCoverage).sorted()) actual=\(Array(coveredSenseIndexes).sorted())"
            )
        }
    }

    func testBaselineRecallDraftsMeetFixedCorpusContractWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "baseline", requireBaseline: true)
        defer { Task { await service.stopServer() } }

        for testCase in recallBaselineCorpus {
            let appContext = appRecallGenerationContext(for: testCase)
            let appAllowedModes = appRecommendedRecallAllowedModes(for: testCase)
            let appModePrior = appRecommendedRecallModePrior(for: testCase)
            let decision = try await service.generateRecallCardDraftDecision(
                word: testCase.word,
                senses: testCase.senses,
                context: appContext,
                allowedModes: appAllowedModes,
                modePrior: appModePrior,
                anchor: testCase.previewAnchor
            )
            let context = failureContext(
                suite: "baseline",
                promptFamily: "recall_draft_decision",
                word: testCase.word,
                modelId: service.selectedModelId
            )

            XCTAssertTrue(!decision.draft.front.isEmpty && !decision.draft.back.isEmpty, "\(context) issue=front/back must both be non-empty")
            XCTAssertTrue(isPlainText(decision.draft.front) && isPlainText(decision.draft.back), "\(context) issue=unexpected markdown or labels in recall draft")
            XCTAssertEqual(decision.draft.back, testCase.word, "\(context) issue=back side must preserve the exact target word or phrase")
            XCTAssertEqual(decision.draft.mode, testCase.expectedMode, "\(context) issue=unexpected recall mode")
            XCTAssertTrue(appAllowedModes.contains(decision.draft.mode), "\(context) issue=returned mode must stay within allowed modes")
            XCTAssertFalse(
                decision.draft.front.containsPinyinDiacritics,
                "\(context) issue=front leaked pinyin or romanization diacritics"
            )
            XCTAssertFalse(
                decision.draft.hint?.containsPinyinDiacritics ?? false,
                "\(context) issue=hint leaked pinyin or romanization diacritics"
            )

            let selectionReason = try XCTUnwrap(
                decision.selectionReason,
                "\(context) issue=selectionReason is required for recall baseline coverage"
            )
            let cuePlan = try XCTUnwrap(
                decision.cuePlan,
                "\(context) issue=cuePlan is required for recall baseline coverage"
            )
            XCTAssertEqual(
                selectionReason.primaryGoal,
                testCase.expectedPrimaryGoal,
                "\(context) issue=unexpected primary goal"
            )
            XCTAssertFalse(selectionReason.evidence.isEmpty, "\(context) issue=selectionReason.evidence must not be empty")
            XCTAssertFalse(cuePlan.normalizedCue.isEmpty, "\(context) issue=cuePlan.normalizedCue must not be empty")
            XCTAssertFalse(
                cuePlanContainsTarget(cuePlan.normalizedCue, target: testCase.word),
                "\(context) issue=cuePlan.normalizedCue must not contain the target word or phrase"
            )

            for needle in testCase.requiredFrontContains {
                XCTAssertTrue(
                    decision.draft.front.contains(needle),
                    "\(context) issue=front missing expected cue substring \(needle)"
                )
            }

            for needle in testCase.requiredFrontExcludes {
                XCTAssertFalse(
                    decision.draft.front.contains(needle),
                    "\(context) issue=front should not contain forbidden substring \(needle)"
                )
            }

            if decision.draft.mode == .targetedLetterCloze {
                let surface = decision.draft.front
                XCTAssertTrue(surface.contains("_"), "\(context) issue=targeted_letter_cloze did not surface an underscore mask")
                XCTAssertEqual(
                    underscoreGroupCount(in: surface),
                    1,
                    "\(context) issue=targeted_letter_cloze must contain exactly one continuous underscore gap"
                )
                let gapLength = longestUnderscoreRun(in: surface)
                XCTAssertGreaterThan(gapLength, 0, "\(context) issue=targeted_letter_cloze gap must not be empty")
                XCTAssertTrue(
                    clozeGapMatchesTarget(surface, target: testCase.word),
                    "\(context) issue=targeted_letter_cloze underscore count must match hidden letter count"
                )
                XCTAssertFalse(surface.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("_"), "\(context) issue=targeted_letter_cloze masked the leading characters first")
                XCTAssertTrue(surface.containsHanScript, "\(context) issue=targeted_letter_cloze front must retain a Chinese cue")
            }
        }
    }

    func testBaselineLearningAidsMeetFixedCorpusContractWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "baseline", requireBaseline: true)
        defer { Task { await service.stopServer() } }

        for testCase in learningAidsBaselineCorpus {
            let ranked = try await service.generateRankedLearningAids(
                word: testCase.word,
                senses: testCase.senses,
                acceptedContext: appLearningAidAcceptedContext(for: testCase),
                anchor: testCase.anchor
            )
            let aids = ranked.aids
            let context = failureContext(
                suite: "baseline",
                promptFamily: "learning_aids",
                word: testCase.word,
                modelId: service.selectedModelId
            )

            XCTAssertTrue(
                aids.pitfalls.allSatisfy { isPlainText($0.summary) && !startsWithListMarker($0.summary) },
                "\(context) issue=pitfall summaries must stay plain and non-bulleted"
            )
            XCTAssertTrue(
                aids.mnemonics.allSatisfy { isPlainText($0.clue) && $0.clue.count <= 80 },
                "\(context) issue=mnemonics must stay concise and plain"
            )
            XCTAssertTrue(
                aids.collocations.allSatisfy {
                    isPlainText($0.phrase)
                        && !$0.phrase.contains("\n")
                        && !$0.phrase.hasSuffix(".")
                        && !$0.phrase.hasSuffix("!")
                        && !$0.phrase.hasSuffix("?")
                },
                "\(context) issue=collocations should look like phrases, not full sentences or markdown"
            )
            if !aids.pitfalls.isEmpty {
                XCTAssertNotNil(ranked.selections.pitfalls, "\(context) issue=missing pitfall ranking selection for non-empty section")
            }
            if !aids.mnemonics.isEmpty {
                XCTAssertNotNil(ranked.selections.mnemonics, "\(context) issue=missing mnemonic ranking selection for non-empty section")
            }
            if !aids.collocations.isEmpty {
                XCTAssertNotNil(ranked.selections.collocations, "\(context) issue=missing collocation ranking selection for non-empty section")
            }
        }
    }

    func testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "comparison")
        defer { Task { await service.stopServer() } }
        let report = try await runLearningAidsStrategyComparison(
            service: service,
            corpus: learningAidsComparisonCorpus3,
            rounds: 2,
            label: "3-word"
        )
        print(report)
    }

    func testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTwoDiagnosticWordsWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "comparison")
        defer { Task { await service.stopServer() } }

        let report = try await runLearningAidsStrategyComparison(
            service: service,
            corpus: learningAidsComparisonCorpus2,
            rounds: 1,
            label: "2-word-diagnostic"
        )
        print(report)
    }

    func testLearningAidsJudgeStrategyComparisonReportsTimingAndQualityAcrossTenWordsWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "comparison")
        defer { Task { await service.stopServer() } }

        let report = try await runLearningAidsStrategyComparison(
            service: service,
            corpus: learningAidsComparisonCorpus10,
            rounds: 1,
            label: "10-word"
        )
        print(report)
    }

    private func configuredServiceOrSkip(suite: String, requireBaseline: Bool = false) throws -> LLMService {
        let environment = ProcessInfo.processInfo.environment
        guard environment[runFlag] == "1" else {
            throw XCTSkip("Set \(runFlag)=1 or run `just test-llm-e2e` to execute optional LLM \(suite) tests.")
        }

        if requireBaseline {
            guard environment[baselineFlag] == "1" else {
                throw XCTSkip("Set \(baselineFlag)=1 and rerun `just test-llm-e2e` to execute the LLM baseline suite.")
            }
        }

        let service = LLMService()
        let downloadedModels = service.registry.models.filter { service.downloadManager.isDownloaded($0) }
        guard !downloadedModels.isEmpty else {
            throw XCTSkip("No downloaded LLM model found for \(suite) suite. Run `just prepare-llm-e2e-model` first, or point \(modelFlag) at an already-downloaded model.")
        }

        if let requestedModelId = environment[modelFlag], !requestedModelId.isEmpty {
            guard downloadedModels.contains(where: { $0.id == requestedModelId }) else {
                throw XCTSkip("Requested model \(requestedModelId) is not downloaded for \(suite) suite.")
            }
            service.selectedModelId = requestedModelId
        } else if service.selectedModelId.isEmpty || !downloadedModels.contains(where: { $0.id == service.selectedModelId }) {
            service.selectedModelId = downloadedModels[0].id
        }

        return service
    }
}

private extension LLMServiceE2ETests {
    struct ExampleSmokeCase {
        let word: String
        let senses: [LLMSensePromptInput]
    }

    struct UsageSmokeCase {
        let word: String
        let senses: [LLMSensePromptInput]
    }

    struct ExampleBaselineCase {
        let word: String
        let senses: [LLMSensePromptInput]
        let expectedCount: Int
        let requiredSenseCoverage: Set<Int>
    }

    struct RecallBaselineCase {
        let id: String
        let word: String
        let senses: [LLMSensePromptInput]
        let acceptedPitfalls: [String]
        let acceptedDefinitionNote: String?
        let acceptedMnemonics: [String]
        let acceptedCollocations: [String]
        let previewAnchor: LLMAnchorSnapshot?
        let expectedMode: LLMRecallCardMode
        let expectedPrimaryGoal: String
        let requiredFrontContains: [String]
        let requiredFrontExcludes: [String]
    }

    struct LearningAidsBaselineCase {
        let word: String
        let senses: [LLMSensePromptInput]
        let acceptedPitfalls: [String]
        let acceptedDefinitionNote: String?
        let acceptedMnemonics: [String]
        let acceptedCollocations: [String]
        let anchor: LLMAnchorSnapshot?
    }

    struct LearningAidStrategyMeasurement {
        let round: Int
        let strategy: LLMLearningAidJudgeStrategy
        let durationMs: Double
        let result: LLMLearningAidsRankedResult
    }

    var exampleBaselineCorpus: [ExampleBaselineCase] {
        [
            ExampleBaselineCase(
                word: "perpetual",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "continuing forever or for a very long time")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1]
            ),
            ExampleBaselineCase(
                word: "light",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "illumination"),
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "not heavy"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "ignite")
                ],
                expectedCount: 3,
                requiredSenseCoverage: [1, 2, 3]
            )
        ]
    }

    var recallBaselineCorpus: [RecallBaselineCase] {
        [
            RecallBaselineCase(
                id: "recall_take_off_phrase",
                word: "take off",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "起飞；脱下", semanticHint: "起飞")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "在飞机语境中表示起飞",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .phraseRecall,
                expectedPrimaryGoal: "phrase_chunk_retrieval",
                requiredFrontContains: [],
                requiredFrontExcludes: []
            ),
            RecallBaselineCase(
                id: "recall_receive_ie_order",
                word: "receive",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "收到；接收", semanticHint: "收到")
                ],
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"],
                acceptedDefinitionNote: nil,
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedPrimaryGoal: "local_spelling_calibration",
                requiredFrontContains: [],
                requiredFrontExcludes: ["receive"]
            ),
            RecallBaselineCase(
                id: "recall_collocation_local_spelling",
                word: "collocation",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "noun",
                        definition: "固定搭配；常见词语搭配",
                        semanticHint: "常见词语搭配"
                    )
                ],
                acceptedPitfalls: ["容易漏掉双写的 ll", "中间元音和后半段顺序容易写错"],
                acceptedDefinitionNote: "指自然的词语搭配，不是任意两个词放在一起",
                acceptedMnemonics: [],
                acceptedCollocations: ["strong collocation"],
                previewAnchor: nil,
                expectedMode: .targetedLetterCloze,
                expectedPrimaryGoal: "local_spelling_calibration",
                requiredFrontContains: ["搭配"],
                requiredFrontExcludes: ["collocation"]
            ),
            RecallBaselineCase(
                id: "recall_perpetual_whole_word",
                word: "perpetual",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "adjective",
                        definition: "持续不断的；长期不止的",
                        semanticHint: "持续不断的"
                    )
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "常用于表示问题、噪音、争论等持续不止",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .fullSpelling,
                expectedPrimaryGoal: "whole_word_recall",
                requiredFrontContains: ["持续"],
                requiredFrontExcludes: ["perpetual"]
            ),
            RecallBaselineCase(
                id: "recall_necessary_resist_signal_bias",
                word: "necessary",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "adjective",
                        definition: "必要的；必需的",
                        semanticHint: "必要的"
                    )
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "表示某事是必须的，不可避免的",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                previewAnchor: nil,
                expectedMode: .fullSpelling,
                expectedPrimaryGoal: "whole_word_recall",
                requiredFrontContains: ["必要"],
                requiredFrontExcludes: ["necessary"]
            ),
            RecallBaselineCase(
                id: "recall_lemmatize_reject_dictionary_jargon_and_pinyin",
                word: "lemmatize",
                senses: [
                    LLMSensePromptInput(
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
                expectedPrimaryGoal: "whole_word_recall",
                requiredFrontContains: [],
                requiredFrontExcludes: ["屈折", "qūzhé", "biànhuà", "lemmatize"]
            )
        ]
    }

    var learningAidsBaselineCorpus: [LearningAidsBaselineCase] {
        [
            LearningAidsBaselineCase(
                word: "charge",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price")
                ],
                acceptedPitfalls: ["容易和负责、收费几个义项混在一起"],
                acceptedDefinitionNote: "表示收费时是让别人支付一笔钱",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: LLMAnchorSnapshot(text: "charge", note: "snapshot only")
            ),
            LearningAidsBaselineCase(
                word: "principal",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "head of a school"),
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "most important")
                ],
                acceptedPitfalls: ["不要和 principle 混淆"],
                acceptedDefinitionNote: "作名词时可指学校负责人",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            )
        ]
    }

    var learningAidsComparisonCorpus3: [LearningAidsBaselineCase] {
        [
            LearningAidsBaselineCase(
                word: "charge",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price")
                ],
                acceptedPitfalls: ["容易和负责、收费几个义项混在一起"],
                acceptedDefinitionNote: "表示收费时是让别人支付一笔钱",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: LLMAnchorSnapshot(text: "charge", note: "snapshot only")
            ),
            LearningAidsBaselineCase(
                word: "principal",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "head of a school"),
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "most important")
                ],
                acceptedPitfalls: ["不要和 principle 混淆"],
                acceptedDefinitionNote: "作名词时可指学校负责人",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "demolish",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "to knock down and destroy a building or structure")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "常指建筑或结构被拆毁",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            )
        ]
    }

    var learningAidsComparisonCorpus10: [LearningAidsBaselineCase] {
        [
            learningAidsComparisonCorpus3[0],
            learningAidsComparisonCorpus3[1],
            learningAidsComparisonCorpus3[2],
            LearningAidsBaselineCase(
                word: "perpetual",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "continuing forever or for a very long time")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "常用于表示问题、噪音、争论等持续不止",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "receive",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "get or be given something")
                ],
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"],
                acceptedDefinitionNote: "表示收到某物，不只是正式接收",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "collocation",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "habitual word pairing", semanticHint: "word pairing")
                ],
                acceptedPitfalls: ["容易漏掉双写的 ll"],
                acceptedDefinitionNote: "指自然的词语搭配，不是任意两个词放在一起",
                acceptedMnemonics: [],
                acceptedCollocations: ["strong collocation"],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "necessary",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "needed in order to achieve something")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "表示某事是必须的，不可避免的",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "fragile",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "easily broken or damaged")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "既可指物理上易碎，也可指关系或制度脆弱",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "reluctant",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "unwilling and hesitant")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "强调不情愿而不是简单地拒绝",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "illuminate",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "light up or make clear")
                ],
                acceptedPitfalls: ["既可以指照亮，也可以指阐明含义"],
                acceptedDefinitionNote: "注意物理照亮和抽象解释两个方向",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            )
        ]
    }

    var learningAidsComparisonCorpus2: [LearningAidsBaselineCase] {
        [
            LearningAidsBaselineCase(
                word: "reluctant",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "unwilling and hesitant")
                ],
                acceptedPitfalls: [],
                acceptedDefinitionNote: "强调不情愿而不是简单地拒绝",
                acceptedMnemonics: [],
                acceptedCollocations: [],
                anchor: nil
            ),
            LearningAidsBaselineCase(
                word: "collocation",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "habitual word pairing", semanticHint: "word pairing")
                ],
                acceptedPitfalls: ["容易漏掉双写的 ll"],
                acceptedDefinitionNote: "指自然的词语搭配，不是任意两个词放在一起",
                acceptedMnemonics: [],
                acceptedCollocations: ["strong collocation"],
                anchor: nil
            )
        ]
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
        return trimmed.range(
            of: #"^(?:[-*•]\s+|\d+\s*[\.\)\:\-–—]\s+)"#,
            options: .regularExpression
        ) != nil
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

    func clozeGapMatchesTarget(_ front: String, target: String) -> Bool {
        let normalizedTarget = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedTarget.isEmpty else { return false }

        for candidate in clozeTokenCandidates(in: front) where underscoreGroupCount(in: candidate) == 1 {
            let gapLength = longestUnderscoreRun(in: candidate)
            guard gapLength > 0,
                  let firstGap = candidate.firstIndex(of: "_"),
                  let lastGap = candidate.lastIndex(of: "_") else {
                continue
            }
            let prefix = String(candidate[..<firstGap]).lowercased()
            let suffix = String(candidate[candidate.index(after: lastGap)...]).lowercased()
            guard !prefix.isEmpty || !suffix.isEmpty else { continue }
            guard normalizedTarget.hasPrefix(prefix),
                  normalizedTarget.hasSuffix(suffix),
                  prefix.count + suffix.count < normalizedTarget.count else {
                continue
            }
            if normalizedTarget.count - prefix.count - suffix.count == gapLength {
                return true
            }
        }
        return false
    }

    func clozeTokenCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        var current = ""

        func flushCurrent() {
            if current.contains("_") {
                candidates.append(current)
            }
            current.removeAll(keepingCapacity: true)
        }

        for character in text {
            if character == "_" || character.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) {
                current.append(character)
            } else {
                flushCurrent()
            }
        }
        flushCurrent()

        return candidates
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

    func appRecallGenerationContext(for testCase: RecallBaselineCase) -> LLMRecallGenerationContext {
        LLMService.normalizeRecallGenerationContext(
            LLMRecallGenerationContext(
                acceptedPitfalls: testCase.acceptedPitfalls,
                acceptedUsageHints: acceptedUsageHints(from: testCase.acceptedDefinitionNote),
                acceptedMnemonics: testCase.acceptedMnemonics,
                acceptedCollocations: testCase.acceptedCollocations
            )
        )
    }

    func appRecommendedRecallAllowedModes(for testCase: RecallBaselineCase) -> [LLMRecallCardMode] {
        LLMService.recommendedRecallAllowedModes(
            for: testCase.word,
            context: appRecallGenerationContext(for: testCase)
        )
    }

    func appRecommendedRecallModePrior(for testCase: RecallBaselineCase) -> LLMRecallCardMode? {
        LLMService.recommendedRecallModePrior(
            for: testCase.word,
            context: appRecallGenerationContext(for: testCase),
            allowedModes: appRecommendedRecallAllowedModes(for: testCase)
        )
    }

    func acceptedUsageHints(from note: String?) -> [String] {
        guard let note else { return [] }
        return note
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func appLearningAidAcceptedContext(for testCase: LearningAidsBaselineCase) -> LLMLearningAidAcceptedContext {
        LLMLearningAidAcceptedContext(
            acceptedPitfalls: testCase.acceptedPitfalls,
            acceptedUsageHints: testCase.acceptedDefinitionNote.map { [$0] } ?? [],
            acceptedMnemonics: testCase.acceptedMnemonics,
            acceptedCollocations: testCase.acceptedCollocations
        )
    }

    func runLearningAidsStrategyComparison(
        service: LLMService,
        corpus: [LearningAidsBaselineCase],
        rounds: Int,
        label: String
    ) async throws -> String {
        var reportLines: [String] = []

        let environment = ProcessInfo.processInfo.environment
        let threadSummary = "threads=\(environment["DICTKIT_LLM_THREADS"] ?? "default") batch_threads=\(environment["DICTKIT_LLM_THREADS_BATCH"] ?? "default")"

        for testCase in corpus {
            let acceptedContext = appLearningAidAcceptedContext(for: testCase)
            var measurements: [LearningAidStrategyMeasurement] = []

            for round in 1...rounds {
                let strategies: [LLMLearningAidJudgeStrategy] = round.isMultiple(of: 2)
                    ? [.combinedSections, .separateSections]
                    : [.separateSections, .combinedSections]

                for strategy in strategies {
                    let measurement = try await measureLearningAidStrategy(
                        service: service,
                        testCase: testCase,
                        acceptedContext: acceptedContext,
                        strategy: strategy,
                        round: round
                    )
                    XCTAssertTrue(
                        isLearningAidResultWellFormed(measurement.result),
                        "strategy=\(strategy.rawValue) word=\(testCase.word) round=\(round)"
                    )
                    measurements.append(measurement)
                }
            }

            reportLines.append(compareSummary(for: testCase, measurements: measurements))
        }

        return "\n=== Learning Aids judge strategy comparison (\(label), \(threadSummary)) ===\n\(reportLines.joined(separator: "\n\n"))\n"
    }

    func measureLearningAidStrategy(
        service: LLMService,
        testCase: LearningAidsBaselineCase,
        acceptedContext: LLMLearningAidAcceptedContext,
        strategy: LLMLearningAidJudgeStrategy,
        round: Int
    ) async throws -> LearningAidStrategyMeasurement {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await service.generateRankedLearningAids(
            word: testCase.word,
            senses: testCase.senses,
            acceptedContext: acceptedContext,
            anchor: testCase.anchor,
            judgeStrategy: strategy
        )
        let elapsed = start.duration(to: clock.now)
        let durationMs = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

        return LearningAidStrategyMeasurement(
            round: round,
            strategy: strategy,
            durationMs: durationMs,
            result: result
        )
    }

    func isLearningAidResultWellFormed(_ ranked: LLMLearningAidsRankedResult) -> Bool {
        let aids = ranked.aids
        return isLearningAidSectionWellFormed(
            items: aids.pitfalls.map(\.id),
            selection: ranked.selections.pitfalls
        ) && isLearningAidSectionWellFormed(
            items: aids.mnemonics.map(\.id),
            selection: ranked.selections.mnemonics
        ) && isLearningAidSectionWellFormed(
            items: aids.collocations.map(\.id),
            selection: ranked.selections.collocations
        )
    }

    func isLearningAidSectionWellFormed(
        items: [String],
        selection: LLMLearningAidSectionSelection?
    ) -> Bool {
        if items.isEmpty {
            return selection == nil || selection?.recommendedID == nil
        }
        guard let selection else { return false }
        if let recommendedID = selection.recommendedID, !items.contains(recommendedID) {
            return false
        }
        return selection.alternativeIDs.allSatisfy(items.contains)
    }

    func compareSummary(
        for testCase: LearningAidsBaselineCase,
        measurements: [LearningAidStrategyMeasurement]
    ) -> String {
        let grouped = Dictionary(grouping: measurements, by: \.strategy)
        let separate = grouped[.separateSections] ?? []
        let combined = grouped[.combinedSections] ?? []

        return [
            "word=\(testCase.word)",
            aggregateSummaryLine(for: .separateSections, measurements: separate, senses: testCase.senses),
            aggregateSummaryLine(for: .combinedSections, measurements: combined, senses: testCase.senses),
            "rounds:",
            measurements
                .sorted {
                    if $0.round == $1.round {
                        return $0.strategy.rawValue < $1.strategy.rawValue
                    }
                    return $0.round < $1.round
                }
                .map { "r\($0.round) " + summaryLine(for: $0, senses: testCase.senses) }
                .joined(separator: "\n")
        ].joined(separator: "\n")
    }

    func aggregateSummaryLine(
        for strategy: LLMLearningAidJudgeStrategy,
        measurements: [LearningAidStrategyMeasurement],
        senses: [LLMSensePromptInput]
    ) -> String {
        guard !measurements.isEmpty else {
            return "\(strategy.rawValue): no measurements"
        }

        let sortedDurations = measurements.map(\.durationMs).sorted()
        let averageMs = sortedDurations.reduce(0, +) / Double(sortedDurations.count)
        let medianMs = sortedDurations[sortedDurations.count / 2]
        let last = measurements.sorted { $0.round < $1.round }.last!

        return "\(strategy.rawValue): avg=\(String(format: "%.1f", averageMs))ms median=\(String(format: "%.1f", medianMs))ms"
            + " | last="
            + sectionSummary("pitfalls", selection: last.result.selections.pitfalls, textByID: Dictionary(uniqueKeysWithValues: last.result.aids.pitfalls.map { ($0.id, $0.summary) }), senses: senses)
            + " | "
            + sectionSummary("mnemonics", selection: last.result.selections.mnemonics, textByID: Dictionary(uniqueKeysWithValues: last.result.aids.mnemonics.map { ($0.id, $0.clue) }), senses: senses)
            + " | "
            + sectionSummary("collocations", selection: last.result.selections.collocations, textByID: Dictionary(uniqueKeysWithValues: last.result.aids.collocations.map { ($0.id, $0.phrase) }), senses: senses)
    }

    func summaryLine(
        for measurement: LearningAidStrategyMeasurement,
        senses: [LLMSensePromptInput]
    ) -> String {
        let ranked = measurement.result
        let pitfallTextByID = Dictionary(uniqueKeysWithValues: ranked.aids.pitfalls.map { ($0.id, $0.summary) })
        let mnemonicTextByID = Dictionary(uniqueKeysWithValues: ranked.aids.mnemonics.map { ($0.id, $0.clue) })
        let collocationTextByID = Dictionary(uniqueKeysWithValues: ranked.aids.collocations.map { ($0.id, $0.phrase) })

        return "\(measurement.strategy.rawValue): \(String(format: "%.1f", measurement.durationMs))ms"
            + " | " + sectionSummary("pitfalls", selection: ranked.selections.pitfalls, textByID: pitfallTextByID, senses: senses)
            + " | " + sectionSummary("mnemonics", selection: ranked.selections.mnemonics, textByID: mnemonicTextByID, senses: senses)
            + " | " + sectionSummary("collocations", selection: ranked.selections.collocations, textByID: collocationTextByID, senses: senses)
    }

    func sectionSummary(
        _ name: String,
        selection: LLMLearningAidSectionSelection?,
        textByID: [String: String],
        senses: [LLMSensePromptInput]
    ) -> String {
        guard let selection,
              let recommendedID = selection.recommendedID,
              let text = textByID[recommendedID] else {
            return "\(name)=none"
        }

        return "\(name)=\(text) [overlap=\(String(format: "%.2f", definitionOverlap(of: text, senses: senses)))]"
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

    func failureContext(
        suite: String,
        promptFamily: String,
        word: String,
        modelId: String,
        issue: String? = nil
    ) -> String {
        var message = "suite=\(suite) prompt=\(promptFamily) word=\(word) model=\(modelId)"
        if let issue {
            message += " issue=\(issue)"
        }
        return message
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
