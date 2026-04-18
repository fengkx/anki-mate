import XCTest
@testable import AnkiMateLLM

final class LLMPromptTests: XCTestCase {
    func testExampleSentenceCountBaselineUsesThreeForSingleSenseAndSenseInventoryForMultiSense() {
        XCTAssertEqual(
            LLMPrompt.exampleSentenceCount(
                for: [LLMSensePromptInput(partOfSpeech: "adjective", definition: "never ending")]
            ),
            3
        )
        XCTAssertEqual(
            LLMPrompt.exampleSentenceCount(
                for: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "illumination"),
                    LLMSensePromptInput(partOfSpeech: "adjective", definition: "not heavy"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "ignite")
                ]
            ),
            3
        )
    }

    func testExamplePromptUsesThreeLinesForSingleSense() {
        let prompt = LLMPrompt.exampleSentences(
            word: "perpetual",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "never ending or changing"
                )
            ]
        )

        XCTAssertTrue(prompt.user.contains("Generate exactly 3 natural English example sentences"))
        XCTAssertTrue(prompt.user.contains("If only one sense is listed, you may generate up to 3 distinct contexts"))
        XCTAssertTrue(prompt.user.contains("Do not use bullets, numbering, labels, or extra markup"))
        XCTAssertTrue(prompt.user.contains("1. adjective: never ending or changing"))
    }

    func testExamplePromptUsesOneLinePerSenseWhenMultipleSensesExist() {
        let senses = [
            LLMSensePromptInput(partOfSpeech: "noun", definition: "illumination"),
            LLMSensePromptInput(partOfSpeech: "adjective", definition: "not heavy"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "ignite")
        ]

        let prompt = LLMPrompt.exampleSentences(word: "light", senses: senses)

        XCTAssertTrue(prompt.user.contains("Generate exactly 3 natural English example sentences"))
        XCTAssertTrue(prompt.user.contains("cover every listed sense before repeating one"))
        XCTAssertTrue(prompt.user.contains("1. noun: illumination"))
        XCTAssertTrue(prompt.user.contains("2. adjective: not heavy"))
        XCTAssertTrue(prompt.user.contains("3. verb: ignite"))
    }

    func testStructuredExamplePromptRequestsSenseIndexedJSON() {
        let prompt = LLMPrompt.exampleSentenceArtifacts(
            word: "charge",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price")
            ]
        )

        XCTAssertTrue(prompt.system.contains("strict JSON"))
        XCTAssertTrue(prompt.user.contains("\"examples\""))
        XCTAssertTrue(prompt.user.contains("\"english\""))
        XCTAssertTrue(prompt.user.contains("\"translation\""))
        XCTAssertTrue(prompt.user.contains("\"senseIndex\""))
        XCTAssertTrue(prompt.user.contains("Return 1 to 2 items in \"examples\""))
        XCTAssertTrue(prompt.user.contains("Prioritize multi-sense coverage over filling a fixed count"))
        XCTAssertTrue(prompt.user.contains("Do not pad with weak, repetitive, or near-duplicate examples"))
        XCTAssertTrue(prompt.user.contains("senseIndex must refer to the numbered sense inventory above"))
        XCTAssertTrue(prompt.user.contains("1. noun: formal accusation"))
        XCTAssertTrue(prompt.user.contains("2. verb: ask someone to pay a price"))
    }

    func testUsagePromptUsesStructuredJSONAndProtectsBoundariesForSingleSense() {
        let prompt = LLMPrompt.optimizeDefinition(
            word: "perpetual",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "never ending or changing"
                )
            ]
        )

        XCTAssertTrue(prompt.system.contains("strict JSON"))
        XCTAssertTrue(prompt.user.contains("\"usageHints\""))
        XCTAssertTrue(prompt.user.contains("\"text\""))
        XCTAssertTrue(prompt.user.contains("\"translation\""))
        XCTAssertTrue(prompt.user.contains("\"kind\""))
        XCTAssertTrue(prompt.user.contains("\"senseIndex\""))
        XCTAssertTrue(prompt.user.contains("Return 1 to 2 items in \"usageHints\""))
        XCTAssertTrue(prompt.user.contains("Do not output spelling warnings, confusable-word alerts, collocation lists, mnemonic slogans, example sentences"))
    }

    func testUsageHintCountBaselineUsesTwoForSingleSenseAndSenseInventoryForMultiSense() {
        XCTAssertEqual(
            LLMPrompt.usageHintCount(
                for: [LLMSensePromptInput(partOfSpeech: "adjective", definition: "never ending")]
            ),
            2
        )
        XCTAssertEqual(
            LLMPrompt.usageHintCount(
                for: [
                    LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price"),
                    LLMSensePromptInput(partOfSpeech: "verb", definition: "fill a battery")
                ]
            ),
            3
        )
    }

    func testUsagePromptPrioritizesSenseCoverageForMultipleSenses() {
        let senses = [
            LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "fill a battery")
        ]

        let prompt = LLMPrompt.optimizeDefinition(word: "charge", senses: senses)

        XCTAssertTrue(prompt.user.contains("Return 1 to 3 items in \"usageHints\""))
        XCTAssertTrue(prompt.user.contains("Prioritize multi-sense coverage over filling a fixed count"))
        XCTAssertTrue(prompt.user.contains("cover every listed sense before expanding on one whenever possible"))
        XCTAssertTrue(prompt.user.contains("1. noun: formal accusation"))
        XCTAssertTrue(prompt.user.contains("2. verb: ask someone to pay a price"))
        XCTAssertTrue(prompt.user.contains("3. verb: fill a battery"))
    }

    func testRecallDraftPromptUsesSingleDraftJSONContractAndAnchorSnapshot() {
        let prompt = LLMPrompt.recallCardDraft(
            word: "take off",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "verb",
                    definition: "leave the ground and begin to fly",
                    semanticHint: "air travel"
                )
            ],
            requestedMode: .targetedLetterCloze,
            anchor: LLMAnchorSnapshot(text: "take ___", note: "UI snapshot only"),
            scaffold: RecallPromptScaffold(
                learnerCue: "起飞；脱掉",
                hint: "verb · air travel",
                requiredMaskedSurface: "ta__ off"
            )
        )

        XCTAssertTrue(prompt.system.contains("strict JSON"))
        XCTAssertTrue(prompt.user.contains("Requested mode:"))
        XCTAssertTrue(prompt.user.contains("targeted_letter_cloze"))
        XCTAssertFalse(prompt.user.contains("Requested modes:"))
        XCTAssertTrue(prompt.user.contains("\"take ___\" [note: UI snapshot only]"))
        XCTAssertTrue(prompt.user.contains("\"draft\""))
        XCTAssertTrue(prompt.user.contains("do not return a \"drafts\" array"))
        XCTAssertTrue(prompt.user.contains("mode must exactly match the requested mode"))
        XCTAssertTrue(prompt.user.contains("single-draft workspace contract"))
        XCTAssertTrue(prompt.user.contains("anchor is optional display metadata only"))
        XCTAssertTrue(prompt.user.contains("back must be the exact target word or phrase"))
        XCTAssertTrue(prompt.user.contains("use exactly one continuous underscore gap of 2 or 3 characters"))
        XCTAssertTrue(prompt.user.contains("Packaging scaffold:"))
        XCTAssertTrue(prompt.user.contains("\"起飞；脱掉\""))
        XCTAssertTrue(prompt.user.contains("\"verb · air travel\""))
        XCTAssertTrue(prompt.user.contains("\"ta__ off\""))
        XCTAssertTrue(prompt.user.contains("copy that masked surface exactly"))
        XCTAssertTrue(prompt.user.contains("Output JSON only"))
    }

    func testLearningAidsPromptRequestsStructuredPitfallsMnemonicsAndCollocations() {
        let prompt = LLMPrompt.learningAids(
            word: "charge",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
                LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price")
            ],
            anchor: LLMAnchorSnapshot(text: "charge", note: "keep raw")
        )

        XCTAssertTrue(prompt.system.contains("strict JSON learning aids"))
        XCTAssertTrue(prompt.user.contains("\"pitfalls\""))
        XCTAssertTrue(prompt.user.contains("\"mnemonics\""))
        XCTAssertTrue(prompt.user.contains("\"collocations\""))
        XCTAssertTrue(prompt.user.contains("\"summary\""))
        XCTAssertTrue(prompt.user.contains("\"clue\""))
        XCTAssertTrue(prompt.user.contains("\"phrase\""))
        XCTAssertTrue(prompt.user.contains("\"charge\" [note: keep raw]"))
        XCTAssertTrue(prompt.user.contains("do not invent source offsets or remap anchors"))
    }

    func testPhoneticIPAPromptRequestsPureIPAJSON() {
        let prompt = LLMPrompt.phoneticIPA(
            word: "collocation",
            dialect: "AmE",
            pronunciationGuide: "käləˈkāshən",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "noun",
                    definition: "habitual word pairing",
                    semanticHint: "word pairing"
                )
            ]
        )

        XCTAssertTrue(prompt.system.contains("Convert dictionary pronunciation guides into strict IPA JSON only"))
        XCTAssertTrue(prompt.user.contains("\"ipa\""))
        XCTAssertTrue(prompt.user.contains("käləˈkāshən"))
        XCTAssertTrue(prompt.user.contains("must be a single IPA string without slashes"))
        XCTAssertTrue(prompt.user.contains("Do not return respelling notation such as SH, TH, CH"))
        XCTAssertTrue(prompt.user.contains("Prefer the requested dialect if one is provided"))
    }

    func testPronunciationEnhancementPromptRequestsStressSyllablesAndOptionalIPA() {
        let prompt = LLMPrompt.pronunciationEnhancement(
            word: "important",
            dialect: "AmE",
            pronunciationGuide: "imˈpôrtnt",
            existingIPA: "ɪmˈpɔːrtənt",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "of great significance"
                )
            ]
        )

        XCTAssertTrue(prompt.system.contains("Convert dictionary pronunciation data into strict JSON only"))
        XCTAssertTrue(prompt.user.contains("\"stressSyllables\""))
        XCTAssertTrue(prompt.user.contains("\"ipa\": \"pure IPA only or null\""))
        XCTAssertTrue(prompt.user.contains("im-POR-tant"))
        XCTAssertTrue(prompt.user.contains("Preserve the original spelling exactly"))
        XCTAssertTrue(prompt.user.contains("aes-THET-ic"))
        XCTAssertTrue(prompt.user.contains("For monosyllable words, return the plain word only, for example \"flock\""))
        XCTAssertTrue(prompt.user.contains("choose one default variant and return one string only"))
        XCTAssertTrue(prompt.user.contains("keep \"ipa\" as null unless correction is necessary"))
        XCTAssertTrue(prompt.user.contains("For multisyllable words, uppercase the primary-stress syllable only"))
    }

    func testPronunciationEnhancementRetryPromptEmphasizesSpellingPreservation() {
        let prompt = LLMPrompt.pronunciationEnhancement(
            word: "aesthetic",
            dialect: "AmE",
            pronunciationGuide: "esˈTHedik",
            existingIPA: "ɛsˈθɛdɪk",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "concerned with beauty"
                )
            ],
            strictSpellingRetry: true
        )

        XCTAssertTrue(prompt.user.contains("Retry correction:"))
        XCTAssertTrue(prompt.user.contains("did not preserve the original written spelling"))
        XCTAssertTrue(prompt.user.contains("copy the original word's letters exactly"))
    }
}
