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
                XCTAssertTrue((2...3).contains(gapLength), "\(context) issue=targeted_letter_cloze gap length must be 2 or 3, got \(gapLength)")
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

            XCTAssertFalse(aids.pitfalls.isEmpty, "\(context) issue=missing pitfalls section")
            XCTAssertFalse(aids.mnemonics.isEmpty, "\(context) issue=missing mnemonics section")
            XCTAssertFalse(aids.collocations.isEmpty, "\(context) issue=missing collocations section")

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
            XCTAssertNotNil(ranked.selections.pitfalls, "\(context) issue=missing pitfall ranking selection")
            XCTAssertNotNil(ranked.selections.mnemonics, "\(context) issue=missing mnemonic ranking selection")
            XCTAssertNotNil(ranked.selections.collocations, "\(context) issue=missing collocation ranking selection")
        }
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
