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

    func testStructuredExamplePromptReplacesGrammarOnlyDefinitionFragments() {
        let prompt = LLMPrompt.exampleSentenceArtifacts(
            word: "therapy",
            senses: [
                LLMSensePromptInput(partOfSpeech: "noun", definition: "and countable"),
                LLMSensePromptInput(
                    partOfSpeech: "noun",
                    definition: "治疗 zhìliáo",
                    semanticHint: "(medical treatment)"
                ),
                LLMSensePromptInput(
                    partOfSpeech: "noun",
                    definition: "心理治疗 xīnlǐ zhìliáo",
                    semanticHint: "(psychotherapy)"
                ),
            ]
        )

        XCTAssertTrue(prompt.user.contains("1. noun: general usage"))
        XCTAssertFalse(prompt.user.contains("noun: and countable"))
        XCTAssertTrue(prompt.user.contains("2. noun: 治疗 zhìliáo [hint: (medical treatment)]"))
        XCTAssertTrue(prompt.user.contains("3. noun: 心理治疗 xīnlǐ zhìliáo [hint: (psychotherapy)]"))
    }

    func testUsagePromptUsesStructuredJSONAndProtectsBoundariesForSingleSense() {
        let prompt = LLMPrompt.usageHints(
            word: "perpetual",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "never ending or changing"
                )
            ]
        )

        XCTAssertTrue(prompt.system.contains("strict JSON"))
        XCTAssertTrue(prompt.system.contains("A usage hint should help the learner choose or recognize the word in context, not just restate the definition."))
        XCTAssertTrue(prompt.user.contains("\"usageHints\""))
        XCTAssertTrue(prompt.user.contains("\"text\""))
        XCTAssertTrue(prompt.user.contains("\"translation\""))
        XCTAssertTrue(prompt.user.contains("\"kind\""))
        XCTAssertTrue(prompt.user.contains("\"senseIndex\""))
        XCTAssertTrue(prompt.user.contains("Return 1 to 2 items in \"usageHints\""))
        XCTAssertTrue(prompt.user.contains("Prefer context, register, contrast, or selection guidance over paraphrasing the dictionary sense"))
        XCTAssertTrue(prompt.user.contains("A good usage hint should help the learner decide when this word fits, what it contrasts with, or what context it usually appears in"))
        XCTAssertTrue(prompt.user.contains("Do not output spelling warnings, confusable-word alerts, collocation lists, mnemonic slogans, example sentences"))
        XCTAssertTrue(prompt.user.contains("Do not restate the dictionary definition in simpler words unless that rewrite adds a real usage boundary"))
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

        let prompt = LLMPrompt.usageHints(word: "charge", senses: senses)

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
        XCTAssertTrue(prompt.user.contains("Card contract"))
        XCTAssertTrue(prompt.user.contains("front is the recall prompt"))
        XCTAssertTrue(prompt.user.contains("back is the exact target answer"))
        XCTAssertTrue(prompt.user.contains("front must not reveal the full back"))
        XCTAssertTrue(prompt.user.contains("back must remain unchanged"))
        XCTAssertTrue(prompt.user.contains("anchor is optional display metadata only"))
        XCTAssertTrue(prompt.user.contains("Cloze rendering contract"))
        XCTAssertTrue(prompt.user.contains("Use exactly one underscore group"))
        XCTAssertTrue(prompt.user.contains("That group must contain 2 or 3 underscores"))
        XCTAssertTrue(prompt.user.contains("front = normalizedCue + maskedTarget"))
        XCTAssertTrue(prompt.user.contains("Packaging scaffold:"))
        XCTAssertTrue(prompt.user.contains("\"起飞；脱掉\""))
        XCTAssertTrue(prompt.user.contains("\"verb · air travel\""))
        XCTAssertFalse(prompt.user.contains("choose the gap position yourself"))
        XCTAssertTrue(prompt.user.contains("Output JSON only"))
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
        XCTAssertFalse(prompt.user.contains("\"selectionReason\""))
        XCTAssertFalse(prompt.user.contains("\"draft\": {"))
        XCTAssertTrue(prompt.user.contains("normalizedCue must be semantic-only Chinese"))
        XCTAssertTrue(prompt.user.contains("normalizedCue must not contain packaging text"))
        XCTAssertTrue(prompt.user.contains("<plan_examples_do_not_copy>"))
        XCTAssertFalse(prompt.user.contains("<front>"))
        XCTAssertFalse(prompt.user.contains("<back>"))
        XCTAssertFalse(prompt.user.contains("masked target surface"))
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
        XCTAssertTrue(prompt.user.contains("English target: lemmatize"))
        XCTAssertTrue(prompt.user.contains("Chinese learner cue: 找到一个词的原始形态"))
        XCTAssertTrue(prompt.user.contains("normalizedCue: 找到一个词的原始形态"))
        XCTAssertTrue(prompt.user.contains("Use cuePlan.normalizedCue as the semantic source of truth for draft.front"))
        XCTAssertTrue(prompt.user.contains("Card contract"))
        XCTAssertTrue(prompt.user.contains("front is the recall prompt"))
        XCTAssertTrue(prompt.user.contains("back is the exact target answer"))
        XCTAssertTrue(prompt.user.contains("<draft_examples_do_not_copy>"))
        XCTAssertFalse(prompt.user.contains("<plan_examples_do_not_copy>"))
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
        XCTAssertTrue(prompt.user.contains("Cloze rendering contract"))
        XCTAssertTrue(prompt.user.contains("Use exactly one underscore group"))
        XCTAssertTrue(prompt.user.contains("That group must contain 2 or 3 underscores"))
        XCTAssertTrue(prompt.user.contains("front = normalizedCue + maskedTarget"))
        XCTAssertTrue(prompt.user.contains("<draft_examples_do_not_copy>"))
        XCTAssertTrue(prompt.user.contains("<target>receive</target>"))
        XCTAssertTrue(prompt.user.contains("<target>collocation</target>"))
        XCTAssertFalse(prompt.user.contains("<target>take off</target>"))
        XCTAssertFalse(prompt.user.contains("屈折"))
        XCTAssertFalse(prompt.user.contains("qūzhé"))
    }

    func testRecallMaskPlanPromptChoosesSubstringWithoutRenderingMask() {
        let prompt = LLMPrompt.recallMaskPlanFromPlan(
            word: "believe",
            senses: [
                LLMSensePromptInput(partOfSpeech: "verb", definition: "相信；认为属实", semanticHint: "相信")
            ],
            context: LLMRecallGenerationContext(
                acceptedPitfalls: ["i 和 e 的顺序很容易写反"]
            ),
            cuePlan: LLMRecallCuePlan(
                semanticSource: "sense_semantic_hint",
                normalizedCue: "相信"
            )
        )

        XCTAssertTrue(prompt.system.contains("You are choosing what to hide, not rendering the final card."))
        XCTAssertTrue(prompt.system.contains("Do not output underscores or a masked word."))
        XCTAssertTrue(prompt.user.contains("Target characters"))
        XCTAssertTrue(prompt.user.contains("1: b"))
        XCTAssertTrue(prompt.user.contains("4: i"))
        XCTAssertTrue(prompt.user.contains("hiddenText"))
        XCTAssertTrue(prompt.user.contains("startIndex is 1-based"))
        XCTAssertFalse(prompt.user.contains("\"focus\""))
        XCTAssertFalse(prompt.user.contains("\"source\""))
        XCTAssertFalse(prompt.user.contains("Valid internal substrings"))
        XCTAssertFalse(prompt.user.contains(#"2: "el""#))
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
        XCTAssertTrue(prompt.user.contains("normalizedCue must be semantic-only Chinese"))
        XCTAssertTrue(prompt.user.contains("normalizedCue must not contain packaging text"))
        XCTAssertTrue(prompt.user.contains("selectedMode must be targeted_letter_cloze"))
        XCTAssertTrue(prompt.user.contains("Do not consider any other mode"))
        XCTAssertTrue(prompt.user.contains("If evidence is mixed, follow modePrior"))
        XCTAssertFalse(prompt.user.contains("masked target surface in front"))
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
        XCTAssertTrue(prompt.system.contains("For mnemonics, consider pronunciation, spelling, imagery, contrast, and plausible word formation"))
        XCTAssertTrue(prompt.system.contains("For pitfalls, think like a language teacher (from a language learner perspective): surface likely learner misunderstandings, similar words misspelling or misuses, not generic advice about better wording."))
        XCTAssertTrue(prompt.system.contains("A pitfall should describe misunderstanding the word itself, not criticizing the practice or style the word refers to."))
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
        XCTAssertTrue(prompt.user.contains("\"kind\": \"sound_hook | image_hook | spelling_hook | contrast_hook | word_structure\""))
        XCTAssertTrue(prompt.user.contains("\"focus\": \"memory_hook | spelling_segment | meaning_contrast | morphology\""))
        XCTAssertTrue(prompt.user.contains("\"phrase\""))
        XCTAssertTrue(prompt.user.contains("\"gloss\""))
        XCTAssertTrue(prompt.user.contains("<learning_aids_context>"))
        XCTAssertTrue(prompt.user.contains("<target>charge</target>"))
        XCTAssertTrue(prompt.user.contains("<sense_inventory>"))
        XCTAssertTrue(prompt.user.contains("<sense index=\"1\">"))
        XCTAssertTrue(prompt.user.contains("<part_of_speech>noun</part_of_speech>"))
        XCTAssertTrue(prompt.user.contains("<definition>formal accusation</definition>"))
        XCTAssertTrue(prompt.user.contains("<accepted_learning_material>"))
        XCTAssertTrue(prompt.user.contains("<pitfalls>none</pitfalls>"))
        XCTAssertTrue(prompt.user.contains("<anchor_snapshot>"))
        XCTAssertTrue(prompt.user.contains("<text>charge</text>"))
        XCTAssertTrue(prompt.user.contains("<note>keep raw</note>"))
        XCTAssertTrue(prompt.user.contains("Target expression contract"))
        XCTAssertTrue(prompt.user.contains("Do not replace the target headword or target expression with a Chinese gloss, translation, or romanization"))
        XCTAssertTrue(prompt.user.contains("Chinese may appear as explanation, gloss, or translation, but it must not replace the expression the learner is supposed to remember"))
        XCTAssertTrue(prompt.user.contains("If you mention the target expression directly, keep the original target surface"))
        XCTAssertTrue(prompt.user.contains("Quality bar"))
        XCTAssertTrue(prompt.user.contains("Every item must be specific to this target word"))
        XCTAssertTrue(prompt.user.contains("If an item is correct but generic, obvious, or weakly memorable, do not return it"))
        XCTAssertTrue(prompt.user.contains("recallRelevant should be true only when the item directly helps active recall"))
        XCTAssertFalse(prompt.user.contains("It is acceptable to return an empty array for any section"))
        XCTAssertTrue(prompt.user.contains("Each section may be empty; weak filler is worse than no item"))
        XCTAssertTrue(prompt.user.contains("Return a raw JSON object only. No markdown fences."))
        XCTAssertTrue(prompt.user.contains("Empty arrays are better than weak items"))
        XCTAssertTrue(prompt.user.contains("A collocation must teach a reusable phrase pattern, not restate the definition"))
        XCTAssertTrue(prompt.user.contains("A mnemonic must still work when the headword is hidden"))
        XCTAssertTrue(prompt.user.contains("Use accepted learning material as already-taught points; the same learning point in different wording or language still counts as overlap"))
        XCTAssertTrue(prompt.user.contains("If accepted material says this word has a double-letter spelling trap, an English rewording of that same trap is still duplicate"))
        XCTAssertTrue(prompt.user.contains("If accepted material already covers the clearest point for a section, return an empty array instead of rewording it"))
        XCTAssertTrue(prompt.user.contains("Stay on the current target word only; never borrow a clue, pitfall, or phrase that fits another word better"))
        XCTAssertTrue(prompt.user.contains("Do not copy wording from the examples below; use them only to learn the quality bar"))
        XCTAssertTrue(prompt.user.contains("pitfalls: require a concrete wrong form, confusable alternative, spelling trap, or misuse context; otherwise return an empty array"))
        XCTAssertTrue(prompt.user.contains("pitfalls: a near-synonym wording contrast is not enough unless it points to a concrete learner mistake"))
        XCTAssertTrue(prompt.user.contains("pitfalls: if accepted pitfalls already cover a spelling trap, do not emit another pitfall whose main information is that same letters or chunk"))
        XCTAssertTrue(prompt.user.contains("pitfalls: write pitfalls as likely learner errors, not generic style advice or editorial preference"))
        XCTAssertTrue(prompt.user.contains("pitfalls: good pitfalls usually name the mistaken interpretation, contrast, or context that would lead the learner astray"))
        XCTAssertTrue(prompt.user.contains("pitfalls: describe confusion about the word's meaning or use, not a judgment about whether the thing it names is good or bad"))
        XCTAssertTrue(prompt.user.contains("pitfalls: avoid turning words like jargon, slang, or formality labels into generic advice about clearer communication"))
        XCTAssertTrue(prompt.user.contains("mnemonics: require a vivid image, a concrete spelling chunk, or a memorable contrast that still works without seeing the headword"))
        XCTAssertTrue(prompt.user.contains("mnemonics: also consider useful word structure, such as prefixes, roots, suffixes, or meaningful chunks"))
        XCTAssertTrue(prompt.user.contains("mnemonics: word-structure hooks must be plausible and learner-facing; do not invent fake etymology"))
        XCTAssertTrue(prompt.user.contains("mnemonics: for abstract words, a concrete scene is acceptable; a synonym paraphrase is not"))
        XCTAssertTrue(prompt.user.contains("mnemonics: no acrostics, no whole-word spelling, no \"think of a <word> person\""))
        XCTAssertTrue(prompt.user.contains("mnemonics: reject abstract slogan-like cues that still require the learner to re-derive the meaning from scratch"))
        XCTAssertTrue(prompt.user.contains("collocations: require a real reusable phrase pattern for this target word, not definition wording and not another word's phrase"))
        XCTAssertTrue(prompt.user.contains("collocations: do not return headword + obvious object phrases that are predictable from the definition alone"))
        XCTAssertTrue(prompt.user.contains("collocations: prefer 1 to 2 high-value collocations; zero is better than filler"))
        XCTAssertTrue(prompt.user.contains("Bad pitfall: fragile -> \"Means weak or delicate\""))
        XCTAssertTrue(prompt.user.contains("Good mnemonic: reluctant -> \"dragging feet at the doorway\""))
        XCTAssertTrue(prompt.user.contains("Good word-structure mnemonic: predictable"))
        XCTAssertTrue(prompt.user.contains("Bad word-structure mnemonic: corpus"))
        XCTAssertTrue(prompt.user.contains("Bad mnemonic: reluctant -> \"Think of a person who is hesitant to agree\""))
        XCTAssertTrue(prompt.user.contains("Bad collocation: principal -> \"principal of the school\""))
        XCTAssertTrue(prompt.user.contains("Why bad: this just restates the dictionary sense instead of teaching a reusable pattern"))
        XCTAssertTrue(prompt.user.contains("If accepted pitfalls already include \"easy to miss the double l\", return an empty pitfall unless you have a genuinely different risk"))
        XCTAssertTrue(prompt.user.contains("do not invent source offsets or remap anchors"))
    }

    func testStructuredExamplePromptAllowsFewerStrongerSingleSenseExamples() {
        let prompt = LLMPrompt.exampleSentenceArtifacts(
            word: "perpetual",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "never ending or changing"
                )
            ]
        )

        XCTAssertTrue(prompt.user.contains("Return 1 to 3 items in \"examples\""))
        XCTAssertTrue(prompt.user.contains("If only one sense is listed, you may return 1 to 3 distinct contexts for that single sense"))
        XCTAssertTrue(prompt.user.contains("Two strong contexts are better than three repetitive ones"))
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
        XCTAssertTrue(prompt.user.contains("For mnemonics, value plausible word-structure hooks when they connect form to meaning or spelling without inventing fake etymology"))
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
        XCTAssertTrue(prompt.user.contains("For mnemonics, value plausible word-structure hooks when they connect form to meaning or spelling without inventing fake etymology"))
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
        XCTAssertTrue(prompt.user.contains("Build stressSyllables using only the exact written target letters, in order"))
        XCTAssertTrue(prompt.user.contains("Use the pronunciation guide only to decide stress placement. Never copy its letters"))
        XCTAssertTrue(prompt.user.contains("For monosyllable words, return the plain word only, e.g. \"flock\""))
        XCTAssertTrue(prompt.user.contains("keep \"ipa\" as null unless correction is necessary"))
    }

    func testPronunciationEnhancementPromptIncludesTargetCharactersForSpellingPreservation() {
        let prompt = LLMPrompt.pronunciationEnhancement(
            word: "corpus",
            dialect: "AmE",
            pronunciationGuide: "KOR-pus",
            existingIPA: "kɔrpəs",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "noun",
                    definition: "a body of written or spoken material"
                )
            ]
        )

        XCTAssertTrue(prompt.user.contains("Target characters"))
        XCTAssertTrue(prompt.user.contains("1: c"))
        XCTAssertTrue(prompt.user.contains("2: o"))
        XCTAssertTrue(prompt.user.contains("3: r"))
        XCTAssertTrue(prompt.user.contains("4: p"))
        XCTAssertTrue(prompt.user.contains("5: u"))
        XCTAssertTrue(prompt.user.contains("6: s"))
        XCTAssertTrue(prompt.user.contains("Build stressSyllables using only the exact written target letters, in order"))
        XCTAssertTrue(prompt.user.contains("Split multi-syllable words into hyphen-joined chunks"))
        XCTAssertTrue(prompt.user.contains("Uppercase only the primary-stressed chunk"))
    }

    func testPronunciationEnhancementRetryPromptIncludesSpecificCorrection() {
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
            retryCorrection: #"Your previous value changed the original spelling. Keep the exact letters of "aesthetic" in the same order and insert hyphens only."#
        )

        XCTAssertTrue(prompt.user.contains("Retry correction:"))
        XCTAssertTrue(prompt.user.contains(#"Your previous value changed the original spelling. Keep the exact letters of "aesthetic" in the same order and insert hyphens only."#))
    }
}
