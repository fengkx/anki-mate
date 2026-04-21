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
            lastSuccessfullyLoadedModelId: nil,
            currentSelectedModelId: "b",
            registryModels: models,
            downloadedModelIDs: ["a", "b"]
        )

        XCTAssertEqual(resolved, "b")
    }

    func testResolveAutoSelectedModelPrefersCurrentDownloadedModelOverLastSuccessfulModel() {
        let models = [
            ModelInfo(id: "a", displayName: "A", fileName: "a.gguf", url: "https://example.com/a.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "b", displayName: "B", fileName: "b.gguf", url: "https://example.com/b.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "c", displayName: "C", fileName: "c.gguf", url: "https://example.com/c.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048)
        ]

        let resolved = LLMService.resolveAutoSelectedModelId(
            lastSuccessfullyLoadedModelId: "c",
            currentSelectedModelId: "b",
            registryModels: models,
            downloadedModelIDs: ["a", "b", "c"]
        )

        XCTAssertEqual(resolved, "b")
    }

    func testResolveAutoSelectedModelFallsBackToLastSuccessfulDownloadedModelWhenCurrentSelectionIsMissing() {
        let models = [
            ModelInfo(id: "a", displayName: "A", fileName: "a.gguf", url: "https://example.com/a.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "b", displayName: "B", fileName: "b.gguf", url: "https://example.com/b.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "c", displayName: "C", fileName: "c.gguf", url: "https://example.com/c.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048)
        ]

        let resolved = LLMService.resolveAutoSelectedModelId(
            lastSuccessfullyLoadedModelId: "c",
            currentSelectedModelId: "missing",
            registryModels: models,
            downloadedModelIDs: ["a", "b", "c"]
        )

        XCTAssertEqual(resolved, "c")
    }

    func testResolveAutoSelectedModelFallsBackToFirstDownloadedRegistryModel() {
        let models = [
            ModelInfo(id: "a", displayName: "A", fileName: "a.gguf", url: "https://example.com/a.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "b", displayName: "B", fileName: "b.gguf", url: "https://example.com/b.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048),
            ModelInfo(id: "c", displayName: "C", fileName: "c.gguf", url: "https://example.com/c.gguf", sizeBytes: 1, quantization: "Q4", contextSize: 2048)
        ]

        let resolved = LLMService.resolveAutoSelectedModelId(
            lastSuccessfullyLoadedModelId: "missing",
            currentSelectedModelId: "missing",
            registryModels: models,
            downloadedModelIDs: ["c", "b"]
        )

        XCTAssertEqual(resolved, "b")
    }

    func testServerLaunchEnvironmentPrependsResolvedLlamaLibraryDirectory() throws {
        let tempRoot = makeTemporaryDirectory()
        let serverBinaryURL = tempRoot
            .appendingPathComponent(".build/debug", isDirectory: true)
            .appendingPathComponent("AnkiMateServer")
        let runtimeLibraryDirectory = tempRoot
            .appendingPathComponent("vendor/llama-install/lib", isDirectory: true)

        try FileManager.default.createDirectory(
            at: runtimeLibraryDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: runtimeLibraryDirectory.appendingPathComponent("libllama.0.dylib"))

        let originalDirectoryPath = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(tempRoot.path)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDirectoryPath)
        }

        let environment = ServerProcessManager.launchEnvironment(
            forServerBinaryAt: serverBinaryURL,
            baseEnvironment: [
                "DYLD_LIBRARY_PATH": "/existing/lib",
                "DYLD_FALLBACK_LIBRARY_PATH": "/fallback/lib"
            ]
        )

        let expectedRuntimePath = runtimeLibraryDirectory.resolvingSymlinksInPath().path
        let dyldRuntimePath = try XCTUnwrap(environment["DYLD_LIBRARY_PATH"]?.split(separator: ":").first.map(String.init))
        let dyldFallbackRuntimePath = try XCTUnwrap(environment["DYLD_FALLBACK_LIBRARY_PATH"]?.split(separator: ":").first.map(String.init))

        XCTAssertEqual(URL(fileURLWithPath: dyldRuntimePath).resolvingSymlinksInPath().path, expectedRuntimePath)
        XCTAssertEqual(URL(fileURLWithPath: dyldFallbackRuntimePath).resolvingSymlinksInPath().path, expectedRuntimePath)
        XCTAssertTrue(environment["DYLD_LIBRARY_PATH"]?.hasSuffix(":/existing/lib") == true)
        XCTAssertTrue(environment["DYLD_FALLBACK_LIBRARY_PATH"]?.hasSuffix(":/fallback/lib") == true)
    }

    func testServerLaunchEnvironmentPrefersBundledFrameworksForAppBundleServer() throws {
        let tempRoot = makeTemporaryDirectory()
        let serverBinaryURL = tempRoot
            .appendingPathComponent("Anki Mate.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("anki-mate-server")
        let frameworksDirectory = tempRoot
            .appendingPathComponent("Anki Mate.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)

        try FileManager.default.createDirectory(
            at: frameworksDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: frameworksDirectory.appendingPathComponent("libllama.0.dylib"))

        let environment = ServerProcessManager.launchEnvironment(
            forServerBinaryAt: serverBinaryURL,
            baseEnvironment: [:]
        )

        let dyldRuntimePath = try XCTUnwrap(environment["DYLD_LIBRARY_PATH"]?.split(separator: ":").first.map(String.init))
        let dyldFallbackRuntimePath = try XCTUnwrap(environment["DYLD_FALLBACK_LIBRARY_PATH"]?.split(separator: ":").first.map(String.init))
        let expectedFrameworksPath = frameworksDirectory.resolvingSymlinksInPath().path

        XCTAssertEqual(URL(fileURLWithPath: dyldRuntimePath).resolvingSymlinksInPath().path, expectedFrameworksPath)
        XCTAssertEqual(URL(fileURLWithPath: dyldFallbackRuntimePath).resolvingSymlinksInPath().path, expectedFrameworksPath)
    }

    func testServerLaunchArgumentsIncludeParentProcessIDWhenProvided() {
        XCTAssertEqual(
            ServerProcessManager.launchArguments(port: 0, parentProcessID: 4242),
            ["0", "--parent-pid", "4242"]
        )
    }

    func testServerLaunchArgumentsOmitParentProcessIDWhenUnavailable() {
        XCTAssertEqual(
            ServerProcessManager.launchArguments(port: 8080, parentProcessID: nil),
            ["8080"]
        )
    }

    func testGpuLayersOverrideDefaultsToMetalFriendlyValue() {
        XCTAssertEqual(LLMService.gpuLayersOverride(environment: [:]), 99)
    }

    func testGpuLayersOverrideReadsEnvironmentAndClampsToZero() {
        XCTAssertEqual(
            LLMService.gpuLayersOverride(environment: ["DICTKIT_LLM_GPU_LAYERS": "0"]),
            0
        )
        XCTAssertEqual(
            LLMService.gpuLayersOverride(environment: ["DICTKIT_LLM_GPU_LAYERS": "-4"]),
            0
        )
        XCTAssertEqual(
            LLMService.gpuLayersOverride(environment: ["DICTKIT_LLM_GPU_LAYERS": "12"]),
            12
        )
    }

    func testContextSizeOverrideDefaultsToModelSetting() {
        XCTAssertEqual(
            LLMService.contextSizeOverride(defaultValue: 131_072, environment: [:]),
            131_072
        )
    }

    func testContextSizeOverrideReadsEnvironmentAndClampsToMinimum() {
        XCTAssertEqual(
            LLMService.contextSizeOverride(
                defaultValue: 131_072,
                environment: ["DICTKIT_LLM_CONTEXT_SIZE": "4096"]
            ),
            4096
        )
        XCTAssertEqual(
            LLMService.contextSizeOverride(
                defaultValue: 131_072,
                environment: ["DICTKIT_LLM_CONTEXT_SIZE": "128"]
            ),
            512
        )
    }

    func testDecodeStructuredRecallDraftAcceptsSingleDraftEnvelopeAndPreservesAnchorSnapshot() throws {
        let payload = """
        ```json
        {
          "draft": {
            "mode": "full_spelling",
            "front": "Front: 根据中文提示写出完整单词",
            "back": "Back: spelling",
            "hint": "Hint: double l",
            "anchor": {
              "text": "speeling",
              "note": "raw OCR snapshot"
            },
          }
        }
        ```
        """

        let decoded = try LLMService.decodeStructuredOutput(
            RecallCardDraftEnvelope.self,
            from: payload
        )
        let drafts = LLMService.normalizeRecallCardDrafts(
            [decoded.primaryDraft].compactMap { $0 },
            requestedModes: [.fullSpelling],
            target: "spelling"
        )

        XCTAssertEqual(drafts.map(\.mode), [.fullSpelling])
        XCTAssertEqual(drafts.first?.front, "根据中文提示写出完整单词")
        XCTAssertEqual(drafts.first?.back, "spelling")
        XCTAssertEqual(drafts.first?.hint, "double l")
        XCTAssertEqual(drafts.first?.anchor?.text, "speeling")
        XCTAssertEqual(drafts.first?.anchor?.note, "raw OCR snapshot")
    }

    func testDecodeStructuredRecallDraftsStillAcceptLegacyDraftArrayAndNormalizeAliases() throws {
        let payload = """
        {
          "drafts": [
            {
              "mode": "targetedLetterCloze",
              "front": "1. Front: 根据提示补全 spe__ing",
              "back": "Back: spelling",
              "hint": "- watch the ll",
              "anchor": null
            }
          ]
        }
        """

        let decoded = try LLMService.decodeStructuredOutput(
            RecallCardDraftEnvelope.self,
            from: payload
        )
        let drafts = LLMService.normalizeRecallCardDrafts(
            decoded.drafts,
            requestedModes: [.targetedLetterCloze],
            target: "spelling"
        )

        XCTAssertEqual(drafts.map(\.mode), [.targetedLetterCloze])
        XCTAssertEqual(drafts.first?.front, "根据提示补全 spe__ing")
        XCTAssertEqual(drafts.first?.back, "spelling")
        XCTAssertEqual(drafts.first?.hint, "watch the ll")
    }

    func testDecodeStructuredRecallDraftRejectsMismatchedBackValue() throws {
        let payload = """
        {
          "drafts": [
            {
              "mode": "targeted_letter_cloze",
              "front": "根据提示补全 spe__ing",
              "back": "speling",
              "hint": "double l"
            }
          ]
        }
        """

        let decoded = try LLMService.decodeStructuredOutput(
            RecallCardDraftEnvelope.self,
            from: payload
        )
        let drafts = LLMService.normalizeRecallCardDrafts(
            decoded.drafts,
            requestedModes: [.targetedLetterCloze],
            target: "spelling"
        )

        XCTAssertTrue(drafts.isEmpty)
    }

    func testRuleBasedRecallDraftBuildsTargetedLetterClozeFallbackForLongWord() throws {
        let draft = try XCTUnwrap(
            LLMService.ruleBasedRecallCardDraft(
                word: "collocation",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "noun",
                        definition: "the habitual juxtaposition of a word with another word"
                    )
                ],
                mode: .targetedLetterCloze,
                anchor: nil
            )
        )

        XCTAssertEqual(draft.mode, .targetedLetterCloze)
        XCTAssertEqual(draft.back, "collocation")
        XCTAssertTrue(draft.front.contains("_"))
        XCTAssertFalse(draft.front.hasPrefix("_"))
        XCTAssertTrue(draft.front.contains("habitual juxtaposition"))
    }

    func testRecallPromptScaffoldBuildsCueAndHintWithoutPresetMask() {
        let scaffold = LLMService.recallPromptScaffold(
            word: "collocation",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "noun",
                    definition: "habitual word pairing",
                    semanticHint: "word pairing"
                )
            ]
        )

        XCTAssertEqual(scaffold.learnerCue, "word pairing")
        XCTAssertEqual(scaffold.hint, "noun · word pairing")
    }

    func testEnforceRecallDraftContractPreservesGeneratedClozeAndBackfillsAnchor() {
        let normalized = LLMService.enforceRecallDraftContract(
            LLMRecallCardDraft(
                mode: .targetedLetterCloze,
                front: "base form · le__atize",
                back: "lemmatize",
                hint: "verb · base form"
            ),
            fallbackAnchor: LLMAnchorSnapshot(text: "lemmatize", note: "snapshot")
        )

        XCTAssertEqual(normalized.front, "base form · le__atize")
        XCTAssertEqual(normalized.back, "lemmatize")
        XCTAssertEqual(normalized.hint, "verb · base form")
        XCTAssertEqual(normalized.anchor?.text, "lemmatize")
    }

    func testRuleBasedRecallDraftFallsBackToPhrasePromptForPhraseRecall() throws {
        let draft = try XCTUnwrap(
            LLMService.ruleBasedRecallCardDraft(
                word: "take off",
                senses: [
                    LLMSensePromptInput(
                        partOfSpeech: "verb",
                        definition: "to leave the ground and begin flying"
                    )
                ],
                mode: .phraseRecall,
                anchor: LLMAnchorSnapshot(text: "take off", note: "phrase")
            )
        )

        XCTAssertEqual(draft.mode, .phraseRecall)
        XCTAssertEqual(draft.back, "take off")
        XCTAssertTrue(draft.front.contains("recall the exact phrase"))
        XCTAssertEqual(draft.anchor?.text, "take off")
    }

    func testNormalizeGeneratedIPAAcceptsPureIPAAndRejectsRespelling() {
        XCTAssertEqual(
            LLMService.normalizeGeneratedIPA(" /ˌkɑləˈkeɪʃən/ "),
            "ˌkɑləˈkeɪʃən"
        )
        XCTAssertNil(LLMService.normalizeGeneratedIPA("käləˈkāSHən"))
    }

    func testNormalizeStressSyllablesAcceptsSingleUppercasedStressSyllable() {
        XCTAssertEqual(
            LLMService.normalizeStressSyllables(" im-POR-tant ", preservingSpellingOf: "important"),
            "im-POR-tant"
        )
        XCTAssertEqual(
            LLMService.normalizeStressSyllables("in-for-MA-tion", preservingSpellingOf: "information"),
            "in-for-MA-tion"
        )
        XCTAssertEqual(
            LLMService.normalizeStressSyllables("aes-Thet-ic", preservingSpellingOf: "aesthetic"),
            "aes-THET-ic"
        )
    }

    func testNormalizeStressSyllablesRejectsInvalidShapes() {
        XCTAssertEqual(LLMService.normalizeStressSyllables("flock", preservingSpellingOf: "flock"), "flock")
        XCTAssertEqual(LLMService.normalizeStressSyllables("FLOCK", preservingSpellingOf: "flock"), "flock")
        XCTAssertEqual(
            LLMService.normalizeStressSyllables("aes-THET-ic, aes-THET-ik", preservingSpellingOf: "aesthetic"),
            "aes-THET-ic"
        )
        XCTAssertNil(LLMService.normalizeStressSyllables("es-THET-ic", preservingSpellingOf: "aesthetic"))
        XCTAssertNil(LLMService.normalizeStressSyllables("im-POR-TANT"))
        XCTAssertNil(LLMService.normalizeStressSyllables("im-POR-tant!"))
    }

    func testDecodeLearningAidsTrimsWhitespaceAndKeepsSectionsSeparate() throws {
        let payload = """
        model output:
        {
          "pitfalls": [
            {
              "summary": "  - Don't confuse it with fee.  ",
              "details": "  * Money asked for service.  ",
              "anchor": { "text": "charge", "note": "snapshot" }
            }
          ],
          "mnemonics": [
            {
              "clue": "  1. charge -> car battery starts charging  ",
              "anchor": null
            }
          ],
          "collocations": [
            {
              "phrase": "  • charge a fee  ",
              "gloss": "  - ask for money  ",
              "anchor": { "text": "charge a fee", "note": "" }
            }
          ]
        }
        extra trailing note
        """

        let decoded = try LLMService.decodeStructuredOutput(
            LearningAidsEnvelope.self,
            from: payload
        )
        let aids = LLMService.normalizeLearningAids(decoded)

        XCTAssertEqual(aids.pitfalls.count, 1)
        XCTAssertEqual(aids.pitfalls[0].summary, "Don't confuse it with fee.")
        XCTAssertEqual(aids.pitfalls[0].details, "Money asked for service.")
        XCTAssertEqual(aids.pitfalls[0].anchor?.text, "charge")
        XCTAssertEqual(aids.mnemonics.map(\.clue), ["charge -> car battery starts charging"])
        XCTAssertEqual(aids.collocations.map(\.phrase), ["charge a fee"])
        XCTAssertEqual(aids.collocations.first?.gloss, "ask for money")
        XCTAssertNil(aids.collocations.first?.anchor?.note)
    }

    func testDecodeLearningAidsAcceptsMarkdownFencedJSONAndNormalizesNestedFields() throws {
        let payload = """
        Here is the output:
        ```json
        {
          "pitfalls": [
            {
              "summary": "  - Avoid raw markdown in the final copy.  ",
              "details": "  * Keep the learner-facing line plain.  ",
              "anchor": { "text": "charge", "note": "  keep original snapshot  " }
            }
          ],
          "mnemonics": [],
          "collocations": []
        }
        ```
        """

        let decoded = try LLMService.decodeStructuredOutput(
            LearningAidsEnvelope.self,
            from: payload
        )
        let aids = LLMService.normalizeLearningAids(decoded)

        XCTAssertEqual(aids.pitfalls.first?.summary, "Avoid raw markdown in the final copy.")
        XCTAssertEqual(aids.pitfalls.first?.details, "Keep the learner-facing line plain.")
        XCTAssertEqual(aids.pitfalls.first?.anchor?.note, "keep original snapshot")
    }

    func testDecodeStructuredUsageHintsNormalizesLabelsAndLegacyKeys() throws {
        let payload = """
        preface
        ```json
        {
          "usage": [
            {
              "summary": "1. Usage: Often describes ongoing problems rather than one-time events.",
              "details": "ZH: 常描述持续存在的问题，而不是一次性事件。",
              "category": "usage tendency",
              "senseIndex": 1
            },
            {
              "english": "Text: Emphasizes repeated continuation rather than fixed permanence.",
              "translation": "Translation: 强调反复持续，而不是固定不变。",
              "kind": "semanticContrast",
              "senseIndex": 1
            }
          ]
        }
        ```
        """

        let decoded = try LLMService.decodeStructuredOutput(
            UsageHintEnvelope.self,
            from: payload
        )
        let hints = LLMService.normalizeUsageHints(
            decoded.usageHints,
            senseCount: 1,
            desiredCount: 2
        )

        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(
            hints.map(\.text),
            [
                "Often describes ongoing problems rather than one-time events.",
                "Emphasizes repeated continuation rather than fixed permanence."
            ]
        )
        XCTAssertEqual(
            hints.map(\.translation),
            [
                "常描述持续存在的问题，而不是一次性事件。",
                "强调反复持续，而不是固定不变。"
            ]
        )
        XCTAssertEqual(hints.map(\.kind), ["usage_tendency", "semantic_contrast"])
        XCTAssertEqual(hints.map(\.senseIndex), [1, 1])
    }

    func testMergeExampleSentencesUsesTopUpToRestoreMissingSenseCoverage() {
        let merged = LLMService.mergeExampleSentences(
            [
                LLMExampleSentence(
                    english: "The kitchen light stayed on all night.",
                    translation: "厨房的灯整晚都亮着。",
                    senseIndex: 1
                ),
                LLMExampleSentence(
                    english: "They light the candles before dinner.",
                    translation: "他们晚饭前点燃蜡烛。",
                    senseIndex: 3
                ),
                LLMExampleSentence(
                    english: "This bag is light enough for travel.",
                    translation: "这个包轻得适合旅行。",
                    senseIndex: nil
                )
            ],
            topUp: [
                LLMExampleSentence(
                    english: "This bag is light enough for travel.",
                    translation: "这个包轻得适合旅行。",
                    senseIndex: 2
                )
            ],
            desiredCount: 3
        )

        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(Set(merged.compactMap(\.senseIndex)), [1, 2, 3])
    }

    func testDecodeStructuredOutputThrowsForNonJSONPayload() {
        XCTAssertThrowsError(
            try LLMService.decodeStructuredOutput(
                LearningAidsEnvelope.self,
                from: "plain text only"
            )
        ) { error in
            guard case LLMServiceError.invalidStructuredOutput(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("Expected JSON object"))
        }
    }

    func testPrimaryResponseTextFallsBackToReasoningContentWhenContentIsEmpty() {
        let response = ChatCompletionResponse(
            choices: [
                .init(
                    message: ChatMessage(
                        role: "assistant",
                        content: nil,
                        reasoning_content: """
                        {"pitfalls":[],"mnemonics":[],"collocations":[]}
                        """
                    )
                )
            ]
        )

        XCTAssertEqual(
            LLMService.primaryResponseText(from: response),
            #"{"pitfalls":[],"mnemonics":[],"collocations":[]}"#
        )
    }

    func testChatCompletionRequestRoundTripsCorrectly() throws {
        let request = ChatCompletionRequest(
            model: "/test.gguf",
            messages: [
                ChatMessage(role: "system", content: "Use JSON"),
                ChatMessage(role: "user", content: "Hello")
            ],
            temperature: 0.2,
            max_tokens: 128,
            tools: [
                ChatTool(
                    function: ChatFunction(
                        name: "lookup",
                        description: "Look up a term",
                        parameters: .object([
                            "type": .string("object"),
                            "properties": .object([
                                "query": .object([
                                    "type": .string("string")
                                ])
                            ]),
                            "required": .array([.string("query")])
                        ])
                    )
                )
            ],
            response_format: ChatResponseFormat(
                type: "json_schema",
                json_schema: ChatJSONSchemaSpec(
                    name: "response",
                    schema: .object(["type": .string("object")]),
                    strict: true
                )
            )
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: data)

        XCTAssertEqual(decoded.model, "/test.gguf")
        XCTAssertEqual(decoded.messages.count, 2)
        XCTAssertEqual(decoded.tools?.first?.function.name, "lookup")
        XCTAssertEqual(decoded.response_format?.type, "json_schema")
        XCTAssertEqual(decoded.max_tokens, 128)
        XCTAssertEqual(decoded.temperature, 0.2)
    }

    func testGenerateResultDecodesLegacyPayloadWithoutFinishReason() throws {
        let payload = #"{"text":"hello","tokensUsed":3,"durationMs":42}"#
        let result = try JSONDecoder().decode(GenerateResult.self, from: Data(payload.utf8))

        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.tokensUsed, 3)
        XCTAssertEqual(result.durationMs, 42)
        XCTAssertNil(result.finishReason)
    }

    func testLearningAidFilterDropsDefinitionParaphrasesAndThinHooks() {
        let senses = [
            LLMSensePromptInput(
                partOfSpeech: "verb",
                definition: "to knock down and destroy a building or structure"
            )
        ]
        let aids = LLMLearningAids(
            pitfalls: [
                LLMPitfall(summary: "Confusing with '拆除'"),
                LLMPitfall(summary: "Do not confuse demolish with damage.")
            ],
            mnemonics: [
                LLMMnemonic(clue: "Knock down"),
                LLMMnemonic(clue: "Picture a wrecking ball")
            ],
            collocations: [
                LLMCollocation(phrase: "demolish a building"),
                LLMCollocation(phrase: "demolish the old wall")
            ]
        )

        let filtered = LLMService.filterLearningAids(aids, word: "demolish", senses: senses)

        XCTAssertEqual(filtered.pitfalls.map(\.summary), ["Do not confuse demolish with damage."])
        XCTAssertEqual(filtered.mnemonics.map(\.clue), ["Picture a wrecking ball"])
        XCTAssertTrue(filtered.collocations.isEmpty)
    }

    func testLearningAidFilterCorpusRejectsDefinitionLevelCollocationsAndTranslatesOnlyHooks() {
        struct FilterCase {
            let word: String
            let senses: [LLMSensePromptInput]
            let aids: LLMLearningAids
            let requiredPitfalls: [String]
            let rejectedPitfalls: [String]
            let requiredMnemonics: [String]
            let rejectedMnemonics: [String]
            let rejectedCollocations: [String]
        }

        let corpus: [FilterCase] = [
            FilterCase(
                word: "demolish",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "to knock down and destroy a building or structure")
                ],
                aids: LLMLearningAids(
                    pitfalls: [
                        LLMPitfall(summary: "Confusing with '拆除'"),
                        LLMPitfall(summary: "Do not confuse demolish with damage.")
                    ],
                    mnemonics: [
                        LLMMnemonic(clue: "Knock down"),
                        LLMMnemonic(clue: "Picture a wrecking ball")
                    ],
                    collocations: [
                        LLMCollocation(phrase: "demolish a building"),
                        LLMCollocation(phrase: "demolish the old wall"),
                        LLMCollocation(phrase: "demolish public confidence")
                    ]
                ),
                requiredPitfalls: ["Do not confuse demolish with damage."],
                rejectedPitfalls: ["Confusing with '拆除'"],
                requiredMnemonics: ["Picture a wrecking ball"],
                rejectedMnemonics: ["Knock down"],
                rejectedCollocations: ["demolish a building", "demolish the old wall"]
            ),
            FilterCase(
                word: "principal",
                senses: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "head of a school"),
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "most important")
                ],
                aids: LLMLearningAids(
                    pitfalls: [
                        LLMPitfall(summary: "不要和 principle 混淆"),
                        LLMPitfall(summary: "Head of a school")
                    ],
                    mnemonics: [
                        LLMMnemonic(clue: "Think of the school head"),
                        LLMMnemonic(clue: "Main = principal")
                    ],
                    collocations: [
                        LLMCollocation(phrase: "principal reason"),
                        LLMCollocation(phrase: "principal of the school")
                    ]
                ),
                requiredPitfalls: ["不要和 principle 混淆"],
                rejectedPitfalls: ["Head of a school"],
                requiredMnemonics: ["Main = principal"],
                rejectedMnemonics: ["Think of the school head"],
                rejectedCollocations: ["principal of the school"]
            )
        ]

        for testCase in corpus {
            let filtered = LLMService.filterLearningAids(
                testCase.aids,
                word: testCase.word,
                senses: testCase.senses
            )

            let pitfallSummaries = filtered.pitfalls.map(\.summary)
            let mnemonicClues = filtered.mnemonics.map(\.clue)
            let collocationPhrases = filtered.collocations.map(\.phrase)

            for expected in testCase.requiredPitfalls {
                XCTAssertTrue(pitfallSummaries.contains(expected), "word=\(testCase.word) missing required pitfall: \(expected)")
            }
            for rejected in testCase.rejectedPitfalls {
                XCTAssertFalse(pitfallSummaries.contains(rejected), "word=\(testCase.word) should reject pitfall: \(rejected)")
            }
            for expected in testCase.requiredMnemonics {
                XCTAssertTrue(mnemonicClues.contains(expected), "word=\(testCase.word) missing required mnemonic: \(expected)")
            }
            for rejected in testCase.rejectedMnemonics {
                XCTAssertFalse(mnemonicClues.contains(rejected), "word=\(testCase.word) should reject mnemonic: \(rejected)")
            }
            for rejected in testCase.rejectedCollocations {
                XCTAssertFalse(collocationPhrases.contains(rejected), "word=\(testCase.word) should reject collocation: \(rejected)")
            }
        }
    }

    func testLearningAidFilterRejectsHabitualBehaviorForCollocation() {
        let senses = [
            LLMSensePromptInput(
                partOfSpeech: "noun",
                definition: "habitual word pairing",
                semanticHint: "word pairing"
            )
        ]
        let aids = LLMLearningAids(
            collocations: [
                LLMCollocation(phrase: "habitual behavior"),
                LLMCollocation(phrase: "strong collocation"),
                LLMCollocation(phrase: "natural collocation")
            ]
        )

        let filtered = LLMService.filterLearningAids(
            aids,
            word: "collocation",
            senses: senses
        )

        XCTAssertFalse(filtered.collocations.map(\.phrase).contains("habitual behavior"))
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
