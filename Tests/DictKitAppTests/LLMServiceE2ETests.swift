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
            let drafts = try await service.generateRecallCardDrafts(
                word: testCase.word,
                senses: testCase.senses,
                modes: testCase.modes,
                anchor: testCase.anchor
            )
            let context = failureContext(
                suite: "baseline",
                promptFamily: "recall_drafts",
                word: testCase.word,
                modelId: service.selectedModelId
            )

            XCTAssertEqual(
                Set(drafts.map(\.mode)),
                Set(testCase.modes),
                "\(context) issue=requested modes \(testCase.modes.map(\.rawValue)) but got \(drafts.map(\.mode.rawValue))"
            )
            XCTAssertTrue(
                drafts.allSatisfy { !$0.front.isEmpty && !$0.back.isEmpty },
                "\(context) issue=front/back must both be non-empty"
            )
            XCTAssertTrue(
                drafts.allSatisfy { isPlainText($0.front) && isPlainText($0.back) },
                "\(context) issue=unexpected markdown or labels in recall draft"
            )
            XCTAssertTrue(
                drafts.allSatisfy { $0.back == testCase.word },
                "\(context) issue=back side must preserve the exact target word or phrase"
            )

            if testCase.modes.contains(.targetedLetterCloze) {
                let targeted = try XCTUnwrap(
                    drafts.first(where: { $0.mode == .targetedLetterCloze }),
                    "\(context) issue=missing targeted_letter_cloze draft"
                )
                let maskedSurface = [targeted.front, targeted.hint ?? ""].joined(separator: " ")
                XCTAssertTrue(
                    maskedSurface.contains("_"),
                    "\(context) issue=targeted_letter_cloze did not surface an underscore mask"
                )
                XCTAssertFalse(
                    maskedSurface.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("_"),
                    "\(context) issue=targeted_letter_cloze masked the leading characters first"
                )
                if let expectedTargetedMask = testCase.expectedTargetedMask {
                    XCTAssertTrue(
                        maskedSurface.contains(expectedTargetedMask),
                        "\(context) issue=targeted_letter_cloze mask drifted expected=\(expectedTargetedMask) actual=\(maskedSurface)"
                    )
                }
            }
        }
    }

    func testBaselineLearningAidsMeetFixedCorpusContractWhenEnabled() async throws {
        let service = try configuredServiceOrSkip(suite: "baseline", requireBaseline: true)
        defer { Task { await service.stopServer() } }

        for testCase in learningAidsBaselineCorpus {
            let aids = try await service.generateLearningAids(
                word: testCase.word,
                senses: testCase.senses,
                anchor: testCase.anchor
            )
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
        let word: String
        let senses: [LLMSensePromptInput]
        let modes: [LLMRecallCardMode]
        let anchor: LLMAnchorSnapshot?
        let expectedTargetedMask: String?
    }

    struct LearningAidsBaselineCase {
        let word: String
        let senses: [LLMSensePromptInput]
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
                word: "take off",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "leave the ground and begin to fly"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "remove clothing")
                ],
                modes: [.fullSpelling, .targetedLetterCloze, .phraseRecall],
                anchor: LLMAnchorSnapshot(text: "take ___", note: "optional snapshot"),
                expectedTargetedMask: nil
            ),
            RecallBaselineCase(
                word: "receive",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "get or accept something that is sent or given")
                ],
                modes: [.fullSpelling, .targetedLetterCloze],
                anchor: nil,
                expectedTargetedMask: nil
            ),
            RecallBaselineCase(
                word: "collocation",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "noun",
                        definition: "habitual word pairing",
                        semanticHint: "word pairing"
                    )
                ],
                modes: [.targetedLetterCloze],
                anchor: nil,
                expectedTargetedMask: "co__ocation"
            ),
            RecallBaselineCase(
                word: "lemmatize",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "verb",
                        definition: "reduce a word to its base form",
                        semanticHint: "base form"
                    )
                ],
                modes: [.targetedLetterCloze],
                anchor: nil,
                expectedTargetedMask: "le__atize"
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
                anchor: LLMAnchorSnapshot(text: "charge", note: "snapshot only")
            ),
            LearningAidsBaselineCase(
                word: "principal",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "head of a school"),
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "most important")
                ],
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
