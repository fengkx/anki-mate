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
                hint: "verb · air travel"
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
        XCTAssertTrue(prompt.user.contains("use exactly one continuous underscore gap"))
        XCTAssertTrue(prompt.user.contains("the number of underscores must exactly match the number of hidden letters"))
        XCTAssertTrue(prompt.user.contains("prefer hiding at least two letters"))
        XCTAssertTrue(prompt.user.contains("Packaging scaffold:"))
        XCTAssertTrue(prompt.user.contains("\"起飞；脱掉\""))
        XCTAssertTrue(prompt.user.contains("\"verb · air travel\""))
        XCTAssertTrue(prompt.user.contains("choose the gap position yourself"))
        XCTAssertTrue(prompt.user.contains("Output JSON only"))
    }

    func testRecallDecisionPromptIncludesLearningAidsAllowedModesAndSelectionReason() {
        let prompt = LLMPrompt.recallCardDecision(
            word: "collocation",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "noun",
                    definition: "固定搭配；常见词语搭配",
                    semanticHint: "常见词语搭配"
                )
            ],
            context: LLMRecallGenerationContext(
                acceptedPitfalls: ["容易漏掉双写的 ll"],
                acceptedUsageHints: ["指自然的词语搭配"],
                acceptedMnemonics: ["co + location of words"],
                acceptedCollocations: ["strong collocation"]
            ),
            allowedModes: [.fullSpelling, .targetedLetterCloze],
            modePrior: .targetedLetterCloze,
            anchor: nil,
            wordSignals: LLMRecallWordSignals(
                isPhrase: false,
                hasRepeatedLetters: true,
                hasConfusableVowelCluster: true
            ),
            scaffold: RecallPromptScaffold(
                learnerCue: "常见词语搭配",
                hint: "noun · 常见词语搭配"
            )
        )

        XCTAssertTrue(prompt.system.contains("strict structured JSON"))
        XCTAssertTrue(prompt.user.contains("Accepted learning aids"))
        XCTAssertTrue(prompt.user.contains("Allowed modes"))
        XCTAssertTrue(prompt.user.contains("Mode prior"))
        XCTAssertTrue(prompt.user.contains("selectionReason"))
        XCTAssertTrue(prompt.user.contains("cuePlan"))
        XCTAssertTrue(prompt.user.contains("choose the gap position yourself"))
        XCTAssertTrue(prompt.user.contains("Do not choose targeted_letter_cloze only because the word is long"))
        XCTAssertTrue(prompt.user.contains("Do not copy pinyin, romanization, or pronunciation respelling into front or hint"))
        XCTAssertTrue(prompt.user.contains("Before writing front, choose one semantic source and rewrite it into a learner-facing cue"))
        XCTAssertTrue(prompt.user.contains("Write cuePlan first, then write draft.front as the final rendered version of cuePlan.normalizedCue"))
        XCTAssertTrue(prompt.user.contains("draft.front must be derived from cuePlan.normalizedCue, not independently rewritten from raw sources"))
        XCTAssertTrue(prompt.user.contains("normalizedCue must be a short learner-facing cue"))
        XCTAssertTrue(prompt.user.contains("do not introduce new dictionary jargon, romanization, or technical wording that is absent from normalizedCue"))
        XCTAssertTrue(prompt.user.contains("prefer the accepted usage hints as the semantic source for front and hint"))
        XCTAssertTrue(prompt.user.contains("rewrite the meaning into natural learner-facing Chinese instead of quoting it"))
        XCTAssertTrue(prompt.user.contains("strip those parts and keep only the learner-facing Chinese meaning"))
        XCTAssertFalse(prompt.user.contains("required masked surface"))
    }

    func testRecallPlanPromptIncludesSourceEvidenceButNoDraftShape() {
        let prompt = LLMPrompt.recallCardPlan(
            word: "lemmatize",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "transitive verb",
                    definition: "把…按屈折变化形式归类 bǎ… àn qūzhé biànhuà xíngshì guīlèi"
                )
            ],
            context: LLMRecallGenerationContext(
                acceptedUsageHints: [
                    "Lemmatize words to find the basic form of a word — 词语的词根或基本形式",
                    "Find the base form of a word — 找到一个词的原始形态"
                ]
            ),
            allowedModes: [.fullSpelling, .targetedLetterCloze],
            modePrior: .fullSpelling,
            anchor: nil,
            wordSignals: LLMRecallWordSignals(
                isPhrase: false,
                hasRepeatedLetters: false,
                hasConfusableVowelCluster: false
            ),
            scaffold: RecallPromptScaffold(
                learnerCue: "找到一个词的原始形态",
                hint: "transitive verb · 找到一个词的原始形态"
            )
        )

        XCTAssertTrue(prompt.user.contains("Sense inventory"))
        XCTAssertTrue(prompt.user.contains("Accepted learning aids"))
        XCTAssertTrue(prompt.user.contains("\"selectedMode\""))
        XCTAssertTrue(prompt.user.contains("\"cuePlan\""))
        XCTAssertFalse(prompt.user.contains("\"draft\": {"))
        XCTAssertTrue(prompt.user.contains("normalizedCue must not contain the exact target word or phrase"))
    }

    func testRecallDraftFromPlanPromptUsesCuePlanAsSoleSemanticSource() {
        let prompt = LLMPrompt.recallCardDraftFromPlan(
            word: "lemmatize",
            selectedMode: .fullSpelling,
            primaryGoal: "whole_word_recall",
            cuePlan: LLMRecallCuePlan(
                semanticSource: "accepted_usage_hint",
                normalizedCue: "找到一个词的原始形态"
            ),
            anchor: nil,
            wordSignals: LLMRecallWordSignals(
                isPhrase: false,
                hasRepeatedLetters: false,
                hasConfusableVowelCluster: false
            ),
            scaffold: RecallPromptScaffold(
                learnerCue: "找到一个词的原始形态",
                hint: "transitive verb · 找到一个词的原始形态"
            )
        )

        XCTAssertTrue(prompt.user.contains("Chosen mode"))
        XCTAssertTrue(prompt.user.contains("Primary goal"))
        XCTAssertTrue(prompt.user.contains("Cue plan"))
        XCTAssertTrue(prompt.user.contains("normalizedCue: 找到一个词的原始形态"))
        XCTAssertTrue(prompt.user.contains("Use cuePlan.normalizedCue as the semantic source of truth for draft.front"))
        XCTAssertTrue(prompt.user.contains("draft.front must be derived from normalizedCue, not independently rewritten from raw sources"))
        XCTAssertFalse(prompt.user.contains("Sense inventory"))
        XCTAssertFalse(prompt.user.contains("Accepted learning aids"))
    }

    func testRecallDraftFromPlanPromptDoesNotExposeRawDictionaryScaffoldCue() {
        let prompt = LLMPrompt.recallCardDraftFromPlan(
            word: "lemmatize",
            selectedMode: .targetedLetterCloze,
            primaryGoal: "local_spelling_calibration",
            cuePlan: LLMRecallCuePlan(
                semanticSource: "accepted_usage_hint",
                normalizedCue: "找到一个词的原始形态"
            ),
            anchor: nil,
            wordSignals: LLMRecallWordSignals(
                isPhrase: false,
                hasRepeatedLetters: true,
                hasConfusableVowelCluster: false
            ),
            scaffold: RecallPromptScaffold(
                learnerCue: "把…按屈折变化形式归类 bǎ… àn qūzhé biànhuà xíngshì guī",
                hint: "transitive verb"
            )
        )

        XCTAssertTrue(prompt.user.contains("normalizedCue: 找到一个词的原始形态"))
        XCTAssertTrue(prompt.user.contains("- learner cue: \"找到一个词的原始形态\""))
        XCTAssertFalse(prompt.user.contains("屈折"))
        XCTAssertFalse(prompt.user.contains("qūzhé"))
    }

    func testRecallPlanPromptForForcedModeStillRequiresNormalizedCue() {
        let prompt = LLMPrompt.recallCardPlan(
            word: "lemmatize",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "transitive verb",
                    definition: "把…按屈折变化形式归类 bǎ… àn qūzhé biànhuà xíngshì guīlèi"
                )
            ],
            context: LLMRecallGenerationContext(
                acceptedUsageHints: [
                    "Find the base form of a word — 找到一个词的原始形态"
                ]
            ),
            allowedModes: [.targetedLetterCloze],
            modePrior: .targetedLetterCloze,
            anchor: nil,
            wordSignals: LLMRecallWordSignals(
                isPhrase: false,
                hasRepeatedLetters: false,
                hasConfusableVowelCluster: false
            ),
            scaffold: RecallPromptScaffold(
                learnerCue: "找到一个词的原始形态",
                hint: "transitive verb · 找到一个词的原始形态"
            )
        )

        XCTAssertTrue(prompt.user.contains("selectedMode must be one of the allowed modes"))
        XCTAssertTrue(prompt.user.contains("normalizedCue must be a short learner-facing cue, not copied raw dictionary wording"))
        XCTAssertTrue(prompt.user.contains("Prefer accepted usage hints over raw sense inventory when they provide a cleaner learner-facing cue"))
        XCTAssertTrue(prompt.user.contains("Even when only one mode is allowed, still choose cuePlan first and normalize the semantic cue before packaging the draft"))
        XCTAssertTrue(prompt.user.contains("Do not let a forced mode justify copying dictionary jargon, formal gloss wording, or bilingual fragments into normalizedCue"))
        XCTAssertTrue(prompt.user.contains("If the forced mode is targeted_letter_cloze, keep the Chinese cue natural and conversational before adding the gap"))
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
        XCTAssertTrue(prompt.system.contains("Use accepted learning material as already-covered teaching points and avoid repeating them. Accepted material may be in Chinese or English; concept overlap still counts."))
        XCTAssertTrue(prompt.system.contains("Your job is not to fill sections."))
        XCTAssertTrue(prompt.system.contains("Prefer omission over low-information correctness."))
        XCTAssertTrue(prompt.user.contains("\"pitfalls\""))
        XCTAssertTrue(prompt.user.contains("\"mnemonics\""))
        XCTAssertTrue(prompt.user.contains("\"collocations\""))
        XCTAssertTrue(prompt.user.contains("\"summary\""))
        XCTAssertTrue(prompt.user.contains("\"translation\""))
        XCTAssertTrue(prompt.user.contains("\"category\""))
        XCTAssertTrue(prompt.user.contains("\"focus\""))
        XCTAssertTrue(prompt.user.contains("\"recallRelevant\""))
        XCTAssertTrue(prompt.user.contains("\"senseIndex\""))
        XCTAssertTrue(prompt.user.contains("\"clue\""))
        XCTAssertTrue(prompt.user.contains("\"phrase\""))
        XCTAssertTrue(prompt.user.contains("\"gloss\""))
        XCTAssertTrue(prompt.user.contains("Accepted learning material"))
        XCTAssertTrue(prompt.user.contains("Quality bar"))
        XCTAssertTrue(prompt.user.contains("Every item must be specific to this target word"))
        XCTAssertTrue(prompt.user.contains("If an item is correct but generic, obvious, or weakly memorable, do not return it"))
        XCTAssertTrue(prompt.user.contains("recallRelevant should be true only when the item directly helps active recall"))
        XCTAssertFalse(prompt.user.contains("It is acceptable to return an empty array for any section"))
        XCTAssertTrue(prompt.user.contains("Each section may be empty; weak filler is worse than no item"))
        XCTAssertTrue(prompt.user.contains("Use accepted learning material as already-taught points; the same learning point in different wording or language still counts as overlap"))
        XCTAssertTrue(prompt.user.contains("If accepted material says this word has a double-letter spelling trap, an English rewording of that same trap is still duplicate"))
        XCTAssertTrue(prompt.user.contains("If accepted material already covers the clearest point for a section, return an empty array instead of rewording it"))
        XCTAssertTrue(prompt.user.contains("Stay on the current target word only; never borrow a clue, pitfall, or phrase that fits another word better"))
        XCTAssertTrue(prompt.user.contains("Do not copy wording from the examples below; use them only to learn the quality bar"))
        XCTAssertTrue(prompt.user.contains("pitfalls: require a concrete wrong form, confusable alternative, spelling trap, or misuse context; otherwise return an empty array"))
        XCTAssertTrue(prompt.user.contains("pitfalls: a near-synonym wording contrast is not enough unless it points to a concrete learner mistake"))
        XCTAssertTrue(prompt.user.contains("pitfalls: if accepted pitfalls already cover a spelling trap, do not emit another pitfall whose main information is that same letters or chunk"))
        XCTAssertTrue(prompt.user.contains("mnemonics: require a vivid image, a concrete spelling chunk, or a memorable contrast that still works without seeing the headword"))
        XCTAssertTrue(prompt.user.contains("mnemonics: for abstract words, a concrete scene is acceptable; a synonym paraphrase is not"))
        XCTAssertTrue(prompt.user.contains("mnemonics: no acrostics, no whole-word spelling, no \"think of a <word> person\""))
        XCTAssertTrue(prompt.user.contains("mnemonics: reject abstract slogan-like cues that still require the learner to re-derive the meaning from scratch"))
        XCTAssertTrue(prompt.user.contains("collocations: require a real reusable phrase pattern for this target word, not definition wording and not another word's phrase"))
        XCTAssertTrue(prompt.user.contains("collocations: do not return headword + obvious object phrases that are predictable from the definition alone"))
        XCTAssertTrue(prompt.user.contains("collocations: prefer 1 to 2 high-value collocations; zero is better than filler"))
        XCTAssertTrue(prompt.user.contains("Bad pitfall: fragile -> \"Means weak or delicate\""))
        XCTAssertTrue(prompt.user.contains("Good mnemonic: reluctant -> \"dragging feet at the doorway\""))
        XCTAssertTrue(prompt.user.contains("Bad mnemonic: reluctant -> \"Think of a person who is hesitant to agree\""))
        XCTAssertTrue(prompt.user.contains("Bad collocation: principal -> \"principal of the school\""))
        XCTAssertTrue(prompt.user.contains("Bad collocation: dismantle -> \"dismantle a machine\""))
        XCTAssertTrue(prompt.user.contains("If accepted pitfalls already include \"easy to miss the double l\", return an empty pitfall unless you have a genuinely different risk"))
        XCTAssertTrue(prompt.user.contains("If accepted collocations already include \"strong collocation\", do not output it again"))
        XCTAssertTrue(prompt.user.contains("\"charge\" [note: keep raw]"))
        XCTAssertTrue(prompt.user.contains("do not invent source offsets or remap anchors"))
    }

    func testLearningAidJudgePromptRequestsRecommendationAndOverlapJSON() {
        let candidatesJSON = """
        [{"id":"cand_1","text":"Do not confuse charge with accuse.","type":"confusable_word"}]
        """
        let acceptedJSON = """
        [{"id":"pitfalls-accepted-0","section":"pitfalls","text":"Do not confuse charge with accuse."}]
        """

        let prompt = LLMPrompt.learningAidJudge(
            section: .pitfalls,
            word: "charge",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation")
            ],
            candidatesJSON: candidatesJSON,
            acceptedJSON: acceptedJSON
        )

        XCTAssertTrue(prompt.system.contains("Choose exactly one recommended item when possible"))
        XCTAssertTrue(prompt.system.contains("Do not rewrite candidates"))
        XCTAssertTrue(prompt.user.contains("Candidates JSON"))
        XCTAssertTrue(prompt.user.contains("Accepted learning material JSON"))
        XCTAssertTrue(prompt.user.contains("\"recommendedId\""))
        XCTAssertTrue(prompt.user.contains("\"alternativeIds\""))
        XCTAssertTrue(prompt.user.contains("\"overlapHints\""))
        XCTAssertTrue(prompt.user.contains("\"whyRecommended\""))
        XCTAssertTrue(
            prompt.user.contains(
                "Do not recommend dictionary glosses, direct translations, definition paraphrases, or trivial headword + obvious object phrases"
            )
        )
        XCTAssertTrue(prompt.user.contains("Overlap means teaching the same learning point even if wording or language differs"))
        XCTAssertTrue(prompt.user.contains("A Chinese accepted item and an English candidate can still overlap if they teach the same trap or distinction"))
    }

    func testLearningAidCombinedJudgePromptRequestsSectionScopedSelections() {
        let candidatesJSON = """
        {"pitfalls":[{"id":"cand_1","text":"Do not confuse charge with accuse.","type":"confusable_word"}],"mnemonics":[],"collocations":[]}
        """
        let acceptedJSON = """
        [{"id":"pitfalls-accepted-0","section":"pitfalls","text":"Do not confuse charge with accuse."}]
        """

        let prompt = LLMPrompt.learningAidCombinedJudge(
            word: "charge",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation")
            ],
            candidatesBySectionJSON: candidatesJSON,
            acceptedJSON: acceptedJSON
        )

        XCTAssertTrue(prompt.system.contains("Judge all learning-aid sections in one pass"))
        XCTAssertTrue(prompt.user.contains("Candidates by section JSON"))
        XCTAssertTrue(prompt.user.contains("\"pitfalls\""))
        XCTAssertTrue(prompt.user.contains("\"mnemonics\""))
        XCTAssertTrue(prompt.user.contains("\"collocations\""))
        XCTAssertTrue(prompt.user.contains("It is acceptable for a section to return null if none of its candidates adds clear learning value"))
        XCTAssertTrue(prompt.user.contains("Do not fill a weak section just to make every section non-empty"))
        XCTAssertTrue(prompt.user.contains("Do not let a strong section suppress selection quality in another section"))
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
