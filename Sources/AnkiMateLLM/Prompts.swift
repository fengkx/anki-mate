// Prompt templates for LLM-powered features.

import Foundation

public struct LLMSensePromptInput: Sendable, Equatable {
    public let partOfSpeech: String
    public let definition: String
    public let semanticHint: String?

    public init(partOfSpeech: String, definition: String, semanticHint: String? = nil) {
        self.partOfSpeech = partOfSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
        self.definition = definition.trimmingCharacters(in: .whitespacesAndNewlines)
        self.semanticHint = semanticHint?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate var inventoryLine: String {
        let hintSuffix: String
        if let semanticHint, !semanticHint.isEmpty {
            hintSuffix = " [hint: \(semanticHint)]"
        } else {
            hintSuffix = ""
        }
        return "\(partOfSpeech): \(definition)\(hintSuffix)"
    }
}

public struct RecallPromptScaffold: Sendable, Equatable {
    public let learnerCue: String?
    public let hint: String?

    public init(
        learnerCue: String?,
        hint: String?
    ) {
        self.learnerCue = learnerCue
        self.hint = hint
    }
}

private enum PromptText {
    static func join(_ sections: [String?]) -> String {
        sections
            .compactMap { section in
                guard let section else {
                    return nil
                }
                let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: "\n\n")
    }

    static func labeledBlock(_ title: String, value: String) -> String {
        "\(title):\n\(value)"
    }

    static func bulletList(_ lines: [String]) -> String {
        lines.map { "- \($0)" }.joined(separator: "\n")
    }

    static func jsonBlock(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    static func compactJSONString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

public enum LLMPrompt {
    static func exampleSentenceCount(for senses: [LLMSensePromptInput]) -> Int {
        let normalizedCount = max(1, senses.count)
        return normalizedCount == 1 ? 3 : normalizedCount
    }

    static func usageHintCount(for senses: [LLMSensePromptInput]) -> Int {
        let normalizedCount = max(1, senses.count)
        return normalizedCount == 1 ? 2 : normalizedCount
    }

    public static func exampleSentences(
        word: String,
        partOfSpeech: String,
        definition: String
    ) -> (system: String, user: String) {
        exampleSentences(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: partOfSpeech,
                    definition: definition
                )
            ]
        )
    }

    public static func exampleSentences(
        word: String,
        senses: [LLMSensePromptInput],
        desiredCount: Int? = nil
    ) -> (system: String, user: String) {
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let desiredCount = desiredCount ?? exampleSentenceCount(for: trimmedSenses)
        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Generate natural English example sentences with concise Chinese translations.",
            "Keep English at B1-B2 level and Chinese idiomatic.",
            "When multiple senses are provided, maximize semantic coverage before repeating a meaning."
        ])

        let user = PromptText.join([
            #"Generate exactly \#(desiredCount) natural English example sentences for the target word "\#(word)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Prioritize a different meaning or part of speech on each line whenever the inventory allows it",
                    "If multiple senses are listed, cover every listed sense before repeating one",
                    "If only one sense is listed, you may generate up to 3 distinct contexts for that single sense",
                    "Use natural, everyday language",
                    "Each sentence should be 8-20 words",
                    "For each item, output in this format: English sentence — Chinese translation",
                    "Do not explain which sense you picked",
                    "Do not use bullets, numbering, labels, or extra markup",
                    "Return ONLY the \(desiredCount) plain lines"
                ])
            )
        ])

        return (system, user)
    }

    public static func exampleSentenceArtifacts(
        word: String,
        senses: [LLMSensePromptInput],
        desiredCount: Int? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let desiredCount = desiredCount ?? exampleSentenceCount(for: trimmedSenses)

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Generate natural English example sentences with concise Chinese translations as strict JSON.",
            "Keep English at B1-B2 level, Chinese idiomatic, and never add markdown fences or commentary."
        ])

        let user = PromptText.join([
            #"Generate structured example sentences for the target word "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"examples\": [",
                "    {",
                "      \"english\": \"natural English sentence using the target word\",",
                "      \"translation\": \"concise Chinese translation\",",
                "      \"senseIndex\": 1",
                "    }",
                "  ]",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "Return 1 to \(desiredCount) items in \"examples\"",
                    "senseIndex must refer to the numbered sense inventory above",
                    "Prioritize multi-sense coverage over filling a fixed count",
                    "If multiple senses are listed, cover every listed sense before repeating one whenever possible",
                    "If only one sense is listed, you may return 1 to \(desiredCount) distinct contexts for that single sense",
                    "Two strong contexts are better than three repetitive ones",
                    "Do not pad with weak, repetitive, or near-duplicate examples just to reach the upper bound",
                    "Use natural, everyday language",
                    "Each English sentence should be 8-20 words",
                    "Keep translation concise and idiomatic",
                    "Do not add labels, bullets, numbering, explanations, or extra fields"
                ])
            )
        ])

        return (system, user)
    }

    public static func usageHints(
        word: String,
        senses: [LLMSensePromptInput]
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let desiredCount = usageHintCount(for: trimmedSenses)

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Generate concise learner-facing usage cues as strict JSON.",
            "Focus on how the word is typically understood or used, and never add markdown fences or commentary.",
            "A usage hint should help the learner choose or recognize the word in context, not just restate the definition."
        ])

        let user = PromptText.join([
            #"Generate structured usage hints for the target word "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"usageHints\": [",
                "    {",
                "      \"text\": \"short learner-facing usage cue\",",
                "      \"translation\": \"简短中文用法提示\",",
                "      \"kind\": \"sense_distinction | usage_tendency | semantic_contrast | register_or_context\",",
                "      \"senseIndex\": 1",
                "    }",
                "  ]",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "Return 1 to \(desiredCount) items in \"usageHints\"",
                    "senseIndex must refer to the numbered sense inventory above",
                    "Prioritize multi-sense coverage over filling a fixed count",
                    "If multiple senses are listed, cover every listed sense before expanding on one whenever possible",
                    "If only one sense is listed, vary the usage angle instead of repeating the same point",
                    "Keep each text concise, learner-facing, and more abstract than an example sentence",
                    "Keep each translation concise and idiomatic",
                    "Prefer context, register, contrast, or selection guidance over paraphrasing the dictionary sense",
                    "A good usage hint should help the learner decide when this word fits, what it contrasts with, or what context it usually appears in",
                    "Do not output spelling warnings, confusable-word alerts, collocation lists, mnemonic slogans, example sentences, or dictionary-definition rewrites",
                    "Do not restate the dictionary definition in simpler words unless that rewrite adds a real usage boundary",
                    "Do not add labels, bullets, numbering, explanations, or extra fields"
                ])
            )
        ])

        return (system, user)
    }

    public static func recallCardDraft(
        word: String,
        senses: [LLMSensePromptInput],
        requestedMode: LLMRecallCardMode,
        anchor: LLMAnchorSnapshot? = nil,
        scaffold: RecallPromptScaffold? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let scaffoldBlock = recallScaffoldText(scaffold, requestedMode: requestedMode)

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Generate one recall-oriented flashcard draft as strict JSON.",
            "Prefer concise learner-facing prompts, keep answers exact, and never add markdown fences or commentary."
        ])

        let user = PromptText.join([
            #"Generate exactly 1 recall card draft for the target "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Requested mode", value: "- \(requestedMode.rawValue)"),
            PromptText.labeledBlock("Anchor snapshot", value: anchorSnapshotText(anchor)),
            PromptText.labeledBlock("Packaging scaffold", value: scaffoldBlock),
            PromptText.labeledBlock(
                "Card contract",
                value: recallCardContractText(target: trimmedWord)
            ),
            requestedMode == .targetedLetterCloze
                ? PromptText.labeledBlock(
                    "Cloze rendering contract",
                    value: recallClozeRenderingContractText()
                )
                : nil,
            PromptText.labeledBlock(
                "Draft examples",
                value: recallDraftExamplesText(for: requestedMode)
            ),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"draft\": {",
                "    \"mode\": \"full_spelling | targeted_letter_cloze | phrase_recall\",",
                "    \"front\": \"final rendered prompt derived from cuePlan.normalizedCue\",",
                "    \"back\": \"exact answer\",",
                "    \"hint\": \"optional short hint or null\",",
                "    \"anchor\": { \"text\": \"optional display snapshot\", \"note\": \"optional note\" } | null",
                "  }",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "Return exactly one draft under \"draft\"; do not return a \"drafts\" array unless you are forced into legacy compatibility",
                    "mode must exactly match the requested mode",
                    "If a learner cue is provided above, use it as the semantic basis of the front instead of drifting to another explanation",
                    "If a short hint is provided above, prefer reusing or lightly polishing it rather than inventing a long hint",
                    "hint is optional and should stay short",
                    "anchor is optional display metadata only; do not invent source offsets or remap anchors",
                    "If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null",
                    "Do not emit alternative modes, numbered options, explanations, or extra fields"
                ])
            )
        ])

        return (system, user)
    }

    public static func recallCardPlan(
        word: String,
        senses: [LLMSensePromptInput],
        context: LLMRecallGenerationContext,
        allowedModes: [LLMRecallCardMode],
        modePrior: LLMRecallCardMode?,
        anchor: LLMAnchorSnapshot? = nil,
        wordSignals: LLMRecallWordSignals,
        scaffold: RecallPromptScaffold? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let normalizedModes = allowedModes.isEmpty ? [.fullSpelling] : allowedModes
        let modeConstraintRules = recallModeConstraintRules(normalizedModes)

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Plan exactly one recall-oriented flashcard as strict structured JSON.",
            "Choose or confirm the recall mode from the allowed modes.",
            "Extract one clean learner-facing semantic cue before any card packaging.",
            "When raw dictionary wording is technical, formal, or mixed with romanization, rewrite it into plain learner-facing Chinese before returning the plan.",
            "Never add markdown fences, commentary, or extra fields."
        ])

        let user = PromptText.join([
            #"Plan exactly 1 recall card for the target "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Accepted learning aids", value: recallLearningAidsText(context)),
            PromptText.labeledBlock("Word signals", value: recallWordSignalsText(wordSignals)),
            PromptText.labeledBlock("Allowed modes", value: recallAllowedModesText(normalizedModes)),
            PromptText.labeledBlock("Mode prior", value: recallModePriorText(modePrior)),
            PromptText.labeledBlock("Anchor snapshot", value: anchorSnapshotText(anchor)),
            PromptText.labeledBlock("Packaging scaffold", value: recallScaffoldText(scaffold, requestedMode: nil)),
            PromptText.labeledBlock(
                "Mode selection contract",
                value: recallModeSelectionContractText()
            ),
            PromptText.labeledBlock(
                "normalizedCue contract",
                value: recallNormalizedCueContractText()
            ),
            PromptText.labeledBlock(
                "Plan examples",
                value: recallPlanExamplesText()
            ),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"selectedMode\": \"full_spelling | targeted_letter_cloze | phrase_recall\",",
                "  \"cuePlan\": {",
                "    \"semanticSource\": \"accepted_usage_hint | sense_semantic_hint | sense_definition_paraphrase | pitfall | collocation\",",
                "    \"normalizedCue\": \"short learner-facing cue before final packaging\"",
                "  }",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "selectedMode must be one of the allowed modes",
                    "cuePlan is required and must explain which semantic source you used",
                    "Use accepted learning aids, word signals, and the sense inventory as evidence",
                    "Return exactly one plan only"
                ] + modeConstraintRules)
            )
        ])

        return (system, user)
    }

    public static func recallCardDraftFromPlan(
        word: String,
        selectedMode: LLMRecallCardMode,
        primaryGoal: String,
        cuePlan: LLMRecallCuePlan,
        anchor: LLMAnchorSnapshot? = nil,
        wordSignals: LLMRecallWordSignals,
        scaffold: RecallPromptScaffold? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCueScaffold = RecallPromptScaffold(
            learnerCue: cuePlan.normalizedCue,
            hint: scaffold?.hint
        )

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Package exactly one recall flashcard draft as strict structured JSON.",
            "Use the supplied cue plan as the semantic source of truth.",
            "Do not re-open or infer new meaning from hidden dictionary sources.",
            "Never add markdown fences, commentary, or extra fields."
        ])

        let user = PromptText.join([
            #"Render exactly 1 recall card draft for the target "\#(trimmedWord)" from the supplied cue plan."#,
            PromptText.labeledBlock("Chosen mode", value: selectedMode.rawValue),
            PromptText.labeledBlock("Primary goal", value: primaryGoal),
            PromptText.labeledBlock("Cue plan", value: [
                "semanticSource: \(cuePlan.semanticSource)",
                "normalizedCue: \(cuePlan.normalizedCue)"
            ].joined(separator: "\n")),
            PromptText.labeledBlock(
                "Card contract",
                value: recallCardContractText(target: trimmedWord, learnerCue: cuePlan.normalizedCue)
            ),
            selectedMode == .targetedLetterCloze
                ? PromptText.labeledBlock(
                    "Cloze rendering contract",
                    value: recallClozeRenderingContractText()
                )
                : nil,
            PromptText.labeledBlock(
                "Draft examples",
                value: recallDraftExamplesText(for: selectedMode)
            ),
            PromptText.labeledBlock("Word signals", value: recallWordSignalsText(wordSignals)),
            PromptText.labeledBlock("Anchor snapshot", value: anchorSnapshotText(anchor)),
            PromptText.labeledBlock("Packaging scaffold", value: recallScaffoldText(normalizedCueScaffold, requestedMode: selectedMode)),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"draft\": {",
                "    \"mode\": \"\(selectedMode.rawValue)\",",
                "    \"front\": \"final learner-facing prompt rendered from normalizedCue\",",
                "    \"back\": \"exact answer\",",
                "    \"hint\": \"optional short hint or null\",",
                "    \"anchor\": { \"text\": \"optional display snapshot\", \"note\": \"optional note\" } | null",
                "  }",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "Use cuePlan.normalizedCue as the semantic source of truth for draft.front",
                    "draft.front must be derived from normalizedCue",
                    "hint is optional and should stay short",
                    "anchor is optional display metadata only; do not invent source offsets or remap anchors",
                    "If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null",
                    "Return exactly one draft only"
                ])
            )
        ])

        return (system, user)
    }

    public static func recallMaskPlanFromPlan(
        word: String,
        senses: [LLMSensePromptInput],
        context: LLMRecallGenerationContext,
        cuePlan: LLMRecallCuePlan
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Choose one useful spelling hotspot for a recall cloze card.",
            "You are choosing what to hide, not rendering the final card.",
            "Do not output underscores or a masked word.",
            "Use the target character list to choose an exact substring.",
            "Never add markdown fences, commentary, or extra fields."
        ])

        let user = PromptText.join([
            #"Choose exactly one spelling hotspot to hide for the target "\#(trimmedWord)"."#,
            "",
            "The learner will see the Chinese cue plus a masked version of the English target.",
            "Your job is to choose the hidden English characters that create the most useful recall challenge.",
            PromptText.labeledBlock("Chosen mode", value: LLMRecallCardMode.targetedLetterCloze.rawValue),
            PromptText.labeledBlock("Cue plan", value: [
                "semanticSource: \(cuePlan.semanticSource)",
                "normalizedCue: \(cuePlan.normalizedCue)"
            ].joined(separator: "\n")),
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Accepted learning aids", value: recallLearningAidsText(context)),
            PromptText.labeledBlock("Target characters", value: targetCharacterListText(for: trimmedWord)),
            PromptText.labeledBlock(
                "Selection guidance",
                value: PromptText.bulletList([
                    "Choose a small internal substring that best matches the learner's likely spelling difficulty.",
                    "Use accepted pitfalls when they reveal a meaningful spelling problem.",
                    "Prefer a useful learning hotspot over a mechanically centered substring.",
                    "Do not choose the first or last character.",
                    "Do not output the final masked word."
                ])
            ),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"maskPlan\": {",
                "    \"startIndex\": 4,",
                "    \"hiddenText\": \"ie\",",
                "    \"teachingReason\": \"This hides the vowel order that learners may reverse.\"",
                "  }",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "startIndex is 1-based",
                    "hiddenText must be copied exactly from the target characters",
                    "hiddenText must be one continuous substring",
                    "hiddenText must be 2 or 3 characters"
                ])
            )
        ])

        return (system, user)
    }

    public static func recallMaskPlanRepair(
        word: String,
        cuePlan: LLMRecallCuePlan,
        validationError: String,
        candidateList: String
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Repair one invalid spelling hotspot plan for a recall cloze card.",
            "Choose from the valid internal substrings only.",
            "Do not output underscores or a masked word.",
            "Never add markdown fences, commentary, or extra fields."
        ])

        let user = PromptText.join([
            "The previous maskPlan failed validation.",
            PromptText.labeledBlock("Target", value: trimmedWord),
            PromptText.labeledBlock("Target characters", value: targetCharacterListText(for: trimmedWord)),
            PromptText.labeledBlock("Cue plan", value: [
                "semanticSource: \(cuePlan.semanticSource)",
                "normalizedCue: \(cuePlan.normalizedCue)"
            ].joined(separator: "\n")),
            PromptText.labeledBlock("Validation error", value: validationError),
            PromptText.labeledBlock("Valid internal substrings", value: candidateList),
            "Choose the best valid substring for the learner's spelling difficulty.",
            "Keep the same meaning and learning goal.",
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"maskPlan\": {",
                "    \"startIndex\": 4,",
                "    \"hiddenText\": \"ie\",",
                "    \"teachingReason\": \"This hides the vowel order that learners may reverse.\"",
                "  }",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "startIndex is 1-based",
                    "hiddenText must be copied exactly from Valid internal substrings",
                    "hiddenText must be one continuous substring",
                    "hiddenText must be 2 or 3 characters"
                ])
            )
        ])

        return (system, user)
    }

    public static func learningAids(
        word: String,
        senses: [LLMSensePromptInput],
        acceptedContext: LLMLearningAidAcceptedContext = .init(),
        anchor: LLMAnchorSnapshot? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Generate strict JSON learning aids for a vocabulary learner.",
            "Your job is not to fill sections. Your job is to return only items that add non-obvious learning value beyond the dictionary senses.",
            "A good item must teach at least one of: a likely learner mistake, a word-specific retrieval hook, or a reusable phrase pattern that is more informative than the definition itself.",
            "For mnemonics, consider pronunciation, spelling, imagery, contrast, and plausible word formation. Use morphology when prefixes, roots, suffixes, or meaningful chunks give a compact retrieval hook.",
            "For pitfalls, think like a language teacher (from a language learner perspective): surface likely learner misunderstandings, similar words misspelling or misuses, not generic advice about better wording.",
            "A pitfall should describe misunderstanding the word itself, not criticizing the practice or style the word refers to.",
            "If a section does not contain that level of value, return an empty array.",
            "Prefer omission over low-information correctness.",
            "Keep every field concise and practical for flashcards.",
            "Use accepted learning material as already-covered teaching points and avoid repeating them. Accepted material may be in Chinese or English; concept overlap still counts.",
            "Prefer returning fewer, stronger items over filling every section with weak content."
        ])

        let user = PromptText.join([
            #"Generate structured learning aids for the target "\#(trimmedWord)"."#,
            learningAidContextXML(
                target: trimmedWord,
                senses: trimmedSenses,
                acceptedContext: acceptedContext,
                anchor: anchor
            ),
            PromptText.labeledBlock(
                "Target expression contract",
                value: PromptText.bulletList([
                    "Do not replace the target headword or target expression with a Chinese gloss, translation, or romanization",
                    "All learning aids must stay centered on the original target expression, even when the sense inventory contains Chinese explanations",
                    "Chinese may appear as explanation, gloss, or translation, but it must not replace the expression the learner is supposed to remember",
                    "If you mention the target expression directly, keep the original target surface: \"\(trimmedWord)\""
                ])
            ),
            PromptText.labeledBlock(
                "Quality bar",
                value: PromptText.bulletList([
	                    "Every item must add information that is not already obvious from the sense inventory",
	                    "Every item must be specific to this target word, not a generic fact that would also fit nearby synonyms",
                    "Every item must save the learner effort: after reading it once, the learner should know what to remember or what mistake to avoid",
                    "If an item is correct but generic, obvious, or weakly memorable, do not return it"
                ])
            ),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"pitfalls\": [",
                "    {",
                "      \"summary\": \"short learner warning\",",
                "      \"translation\": \"简短中文解释\",",
                "      \"category\": \"spelling_trap | confusable_word | meaning_misdirection | common_misuse\",",
                "      \"focus\": \"spelling_segment | meaning_contrast | misuse_pattern | usage_context\",",
                "      \"recallRelevant\": true,",
                "      \"senseIndex\": 1,",
                "      \"details\": \"optional extra explanation\",",
                "      \"anchor\": { \"text\": \"optional display snapshot\", \"note\": \"optional note\" } | null",
                "    }",
                "  ],",
                "  \"mnemonics\": [",
                "    {",
                "      \"clue\": \"very short mnemonic cue\",",
                "      \"translation\": \"可选中文提示\",",
                "      \"kind\": \"sound_hook | image_hook | spelling_hook | contrast_hook | word_structure\",",
                "      \"focus\": \"memory_hook | spelling_segment | meaning_contrast | morphology\",",
                "      \"recallRelevant\": true,",
                "      \"senseIndex\": 1,",
                "      \"anchor\": { \"text\": \"optional display snapshot\", \"note\": \"optional note\" } | null",
                "    }",
                "  ],",
                "  \"collocations\": [",
                "    {",
                "      \"phrase\": \"common collocation or pattern\",",
                "      \"gloss\": \"optional short usage gloss\",",
                "      \"focus\": \"phrase_pattern | usage_context\",",
                "      \"recallRelevant\": false,",
                "      \"senseIndex\": 1,",
                "      \"anchor\": { \"text\": \"optional display snapshot\", \"note\": \"optional note\" } | null",
                "    }",
                "  ]",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Return a raw JSON object only. No markdown fences.",
                    "Empty arrays are better than weak items",
                    "Do not repeat accepted material in another wording or another language",
                    "A collocation must teach a reusable phrase pattern, not restate the definition",
                    "A mnemonic must still work when the headword is hidden",
                    "Return JSON only",
                    "Each section may be empty; weak filler is worse than no item",
                    "Use accepted learning material as already-taught points; the same learning point in different wording or language still counts as overlap",
                    "If accepted material says this word has a double-letter spelling trap, an English rewording of that same trap is still duplicate",
                    "If accepted material already covers the clearest point for a section, return an empty array instead of rewording it",
                    "Stay on the current target word only; never borrow a clue, pitfall, or phrase that fits another word better",
                    "Do not copy wording from the examples below; use them only to learn the quality bar",
                    "Never output self-reference, direct definition restatements, translation rewrites, or gloss-wording contrasts",
                    "Target output budget: pitfalls 0 to 2, mnemonics 0 to 2, collocations 0 to 2",
                    "Do not use the full budget unless each item clearly passes the quality bar",
                    "pitfalls: require a concrete wrong form, confusable alternative, spelling trap, or misuse context; otherwise return an empty array",
                    "pitfalls: a near-synonym wording contrast is not enough unless it points to a concrete learner mistake",
                    "pitfalls: if accepted pitfalls already cover a spelling trap, do not emit another pitfall whose main information is that same letters or chunk",
                    "pitfalls: reject vague nuance comments that do not predict a real learner error",
                    "pitfalls: write pitfalls as likely learner errors, not generic style advice or editorial preference",
                    "pitfalls: good pitfalls usually name the mistaken interpretation, contrast, or context that would lead the learner astray",
                    "pitfalls: describe confusion about the word's meaning or use, not a judgment about whether the thing it names is good or bad",
                    "pitfalls: avoid turning words like jargon, slang, or formality labels into generic advice about clearer communication",
                    "mnemonics: require a vivid image, a concrete spelling chunk, or a memorable contrast that still works without seeing the headword",
                    "mnemonics: also consider useful word structure, such as prefixes, roots, suffixes, or meaningful chunks, when it helps connect form to meaning or spelling",
                    "mnemonics: word-structure hooks must be plausible and learner-facing; do not invent fake etymology just to make a clever story",
                    "mnemonics: for abstract words, a concrete scene is acceptable; a synonym paraphrase is not",
                    "mnemonics: no acrostics, no whole-word spelling, no \"think of a <word> person\"",
                    "mnemonics: reject abstract slogan-like cues that still require the learner to re-derive the meaning from scratch",
                    "mnemonics: if the clue stops working once the headword is hidden, it is too weak",
                    "collocations: require a real reusable phrase pattern for this target word, not definition wording and not another word's phrase",
                    "collocations: do not return headword + obvious object phrases that are predictable from the definition alone",
                    "collocations: do not return broad phrases that would work just as well with several close synonyms",
                    "collocations: prefer patterns that reveal register, argument structure, or a typical semantic environment",
                    "collocations: prefer 1 to 2 high-value collocations; zero is better than filler",
                    "collocations: if you cannot name a phrase that would make the learner noticeably better at using or recognizing this word, return an empty array",
                    "recallRelevant should be true only when the item directly helps active recall, hint design, or mistake avoidance",
                    "senseIndex is optional and should refer to the numbered sense inventory above when provided",
                    "Keep every string compact and learner-facing",
                    "anchor is optional display metadata only; do not invent source offsets or remap anchors"
                ])
            ),
            PromptText.labeledBlock(
                "Examples",
                value: PromptText.bulletList([
                    "Good mnemonic: reluctant -> \"dragging feet at the doorway\"",
                    "Good word-structure mnemonic: predictable -> \"pre- says before; dict says say: can be said before it happens\"",
                    "Bad mnemonic: reluctant -> \"Think of a person who is hesitant to agree\"",
                    "Bad word-structure mnemonic: corpus -> \"cor + pus means data\"",
                    "Bad pitfall: fragile -> \"Means weak or delicate\"",
                    "Bad collocation: principal -> \"principal of the school\"",
                    "Why bad: this just restates the dictionary sense instead of teaching a reusable pattern",
                    "If accepted pitfalls already include \"easy to miss the double l\", return an empty pitfall unless you have a genuinely different risk"
                ])
            )
        ])

        return (system, user)
    }

    public static func learningAidJudge(
        section: LLMLearningAidSection,
        word: String,
        senses: [LLMSensePromptInput],
        candidatesJSON: String,
        acceptedJSON: String
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses

        let system = PromptText.join([
            "You are selecting the most useful learning aid candidate for a vocabulary learner.",
            "Choose exactly one recommended item when possible, keep overlap advisory, and return strict JSON only. When accepted material already covers a candidate's main point, prefer null over recommendation.",
            "Do not rewrite candidates. Do not invent new content."
        ])

        let user = PromptText.join([
            #"Select the default recommendation for the "\#(section.rawValue)" section of "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Candidates JSON", value: candidatesJSON),
            PromptText.labeledBlock("Accepted learning material JSON", value: acceptedJSON),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"recommendedId\": \"candidate id or null\",",
                "  \"alternativeIds\": [\"candidate ids that remain valid alternatives\"],",
                "  \"overlapHints\": [",
                "    {",
                "      \"candidateId\": \"candidate id\",",
                "      \"overlapType\": \"accepted_overlap | candidate_overlap\",",
                "      \"withItemId\": \"accepted or candidate id\",",
                "      \"reason\": \"short explanation\"",
                "    }",
                "  ],",
                "  \"whyRecommended\": \"one short sentence\"",
                "}"
            ]),
            PromptText.labeledBlock(
                "Selection principles",
                value: PromptText.bulletList([
                    "Only consider candidates that add information the sense inventory does not already state plainly",
                    "Do not recommend dictionary glosses, direct translations, definition paraphrases, or trivial headword + obvious object phrases",
                    "Pick one candidate that adds the most learning value if the learner accepts only one item in this section",
                    "Prefer short, specific, actionable items",
                    "Prefer candidates that help recall or help avoid likely mistakes",
                    "For mnemonics, value plausible word-structure hooks when they connect form to meaning or spelling without inventing fake etymology",
                    "Avoid recommending candidates whose main learning point is already covered by accepted material",
                    "A Chinese accepted item and an English candidate can still overlap if they teach the same trap or distinction",
                    "Overlap means teaching the same learning point even if wording or language differs",
                    "If a candidate's main learning point is already covered by accepted material, return null instead of recommending it",
                    "Keep overlap advisory only for alternatives that remain genuinely useful from a different angle",
                    "Do not rank by style alone and do not choose generic filler sentences",
                    "Return JSON only"
                ])
            )
        ])

        return (system, user)
    }

    public static func learningAidCombinedJudge(
        word: String,
        senses: [LLMSensePromptInput],
        candidatesBySectionJSON: String,
        acceptedJSON: String
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses

        let system = PromptText.join([
            "You are selecting the most useful learning aid candidates for a vocabulary learner.",
            "Judge all learning-aid sections in one pass, keep overlap advisory, and return strict JSON only. When accepted material already covers a candidate's main point, prefer null.",
            "Do not rewrite candidates. Do not invent new content.",
            "A weak section may legitimately return null rather than forcing a recommendation."
        ])

        let user = PromptText.join([
            #"Select the default recommendation for each learning-aid section of "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Candidates by section JSON", value: candidatesBySectionJSON),
            PromptText.labeledBlock("Accepted learning material JSON", value: acceptedJSON),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"pitfalls\": {",
                "    \"recommendedId\": \"candidate id or null\",",
                "    \"alternativeIds\": [\"candidate ids that remain valid alternatives\"],",
                "    \"overlapHints\": [",
                "      {",
                "        \"candidateId\": \"candidate id\",",
                "        \"overlapType\": \"accepted_overlap | candidate_overlap\",",
                "        \"withItemId\": \"accepted or candidate id\",",
                "        \"reason\": \"short explanation\"",
                "      }",
                "    ],",
                "    \"whyRecommended\": \"one short sentence\"",
                "  } | null,",
                "  \"mnemonics\": { ...same shape... } | null,",
                "  \"collocations\": { ...same shape... } | null",
                "}"
            ]),
            PromptText.labeledBlock(
                "Selection principles",
                value: PromptText.bulletList([
                    "Judge each section independently even though all sections are provided together",
                    "It is acceptable for a section to return null if none of its candidates adds clear learning value",
                    "Only consider candidates that add information the sense inventory does not already state plainly",
                    "Do not recommend dictionary glosses, direct translations, definition paraphrases, or trivial headword + obvious object phrases",
                    "Do not fill a weak section just to make every section non-empty",
                    "Pick one candidate per non-empty section that adds the most learning value if the learner accepts only one item in that section",
                    "Prefer short, specific, actionable items",
                    "Prefer candidates that help recall or help avoid likely mistakes",
                    "For mnemonics, value plausible word-structure hooks when they connect form to meaning or spelling without inventing fake etymology",
                    "Avoid recommending candidates whose main learning point is already covered by accepted material",
                    "A Chinese accepted item and an English candidate can still overlap if they teach the same trap or distinction",
                    "Prefer no recommendation over a low-increment recommendation",
                    "Use candidate_overlap when two candidates from the same section teach the same learning point",
                    "Overlap means teaching the same learning point even if wording or language differs",
                    "If a candidate's main learning point is already covered by accepted material, return null for that section instead of recommending it",
                    "Keep overlap advisory only for alternatives that remain genuinely useful from a different angle",
                    "Do not let a strong section suppress selection quality in another section",
                    "Return JSON only"
                ])
            )
        ])

        return (system, user)
    }

    public static func phoneticIPA(
        word: String,
        dialect: String?,
        pronunciationGuide: String?,
        senses: [LLMSensePromptInput]
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let normalizedDialect = dialect?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedDialect = normalizedDialect.isEmpty ? nil : normalizedDialect
        let normalizedGuide = pronunciationGuide?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedGuide = normalizedGuide.isEmpty ? nil : normalizedGuide

        let system = PromptText.join([
            "You are a pronunciation specialist.",
            "Convert dictionary pronunciation guides into strict IPA JSON only.",
            "Never return respelling, never add slashes, and never add explanations."
        ])

        let user = PromptText.join([
            #"Generate a single IPA pronunciation for the target word "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Dialect", value: trimmedDialect ?? "unspecified"),
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock(
                "Existing pronunciation guide",
                value: trimmedGuide.map { "\"\($0)\"" } ?? "none"
            ),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"ipa\": \"pure IPA only\"",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "\"ipa\" must be a single IPA string without slashes",
                    "Do not return respelling notation such as SH, TH, CH, or uppercase helper text",
                    "Do not include the headword, labels, bullets, markdown, or commentary",
                    "Prefer the requested dialect if one is provided",
                    "Use the pronunciation guide as a hint only; correct it into real IPA"
                ])
            )
        ])

        return (system, user)
    }

    public static func pronunciationEnhancement(
        word: String,
        dialect: String?,
        pronunciationGuide: String?,
        existingIPA: String?,
        senses: [LLMSensePromptInput],
        retryCorrection: String? = nil,
        isRetry: Bool = false
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let normalizedDialect = dialect?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedDialect = normalizedDialect.isEmpty ? nil : normalizedDialect
        let normalizedGuide = pronunciationGuide?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedGuide = normalizedGuide.isEmpty ? nil : normalizedGuide
        let normalizedExistingIPA = existingIPA?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedExistingIPA = normalizedExistingIPA.isEmpty ? nil : normalizedExistingIPA

        let system = PromptText.join([
            "You are a pronunciation specialist.",
            "Convert dictionary pronunciation data into strict JSON only.",
            "Never return respelling as IPA, never add slashes, and never add explanations."
        ])

        let retryReminder = retryCorrection.map { correction in
            PromptText.join([
                "Retry correction:",
                correction
            ])
        }

        let contextBlocks: [String?] = isRetry
            ? [retryReminder]
            : [
                PromptText.labeledBlock("Dialect", value: trimmedDialect ?? "unspecified"),
                PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
                PromptText.labeledBlock(
                    "Existing pronunciation guide",
                    value: trimmedGuide.map { "\"\($0)\"" } ?? "none"
                ),
                PromptText.labeledBlock(
                    "Existing IPA",
                    value: trimmedExistingIPA.map { "\"\($0)\"" } ?? "none"
                ),
                retryReminder
            ]

        let rulesBlock = PromptText.labeledBlock(
            "Rules",
            value: [
                "Spelling invariant (MUST):",
                PromptText.bulletList([
                    "stressSyllables is a spelling display, not a pronunciation respelling",
                    "Build stressSyllables using only the exact written target letters, in order",
                    "After removing hyphens and lowercasing, stressSyllables must equal the target word exactly",
                    "Use the pronunciation guide only to decide stress placement. Never copy its letters",
                    "A single all-uppercase chunk without hyphens is invalid for multi-syllable words"
                ]),
                "",
                "Format:",
                PromptText.bulletList([
                    "Split multi-syllable words into hyphen-joined chunks",
                    "Uppercase only the primary-stressed chunk",
                    "For monosyllable words, return the plain word only, e.g. \"flock\""
                ]),
                "",
                "Before returning:",
                PromptText.bulletList([
                    "Check: strip hyphens + lowercase the result. It must equal the target word in lowercase.",
                    "If not equal, fix stressSyllables now before outputting."
                ]),
                "",
                "Output:",
                PromptText.bulletList([
                    "Output JSON only",
                    "\"stressSyllables\" is required",
                    "Do not include spaces, labels, markdown, commentary, slashes, or alternatives in the string"
                ]),
                "",
                "IPA:",
                PromptText.bulletList([
                    "If existing IPA is already provided, keep \"ipa\" as null unless correction is necessary",
                    "If \"ipa\" is present, it must be a single IPA string without slashes",
                    "Do not return respelling notation such as SH, TH, CH as IPA",
                    "Use the pronunciation guide as a hint only; correct it into real IPA when needed"
                ])
            ].joined(separator: "\n")
        )

        let user = PromptText.join([
            #"Generate pronunciation enhancement data for the target word "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Target characters", value: targetCharacterListText(for: trimmedWord)),
            PromptText.join(contextBlocks.compactMap { $0 }),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"ipa\": \"pure IPA only or null\",",
                "  \"stressSyllables\": \"hyphen-joined syllables with the primary-stress syllable uppercased\"",
                "}"
            ]),
            rulesBlock
        ])

        return (system, user)
    }

    private static func senseInventoryText(from senses: [LLMSensePromptInput]) -> String {
        guard !senses.isEmpty else {
            return "1. general: no sense inventory provided"
        }

        return senses.enumerated().map { index, sense in
            "\(index + 1). \(sense.inventoryLine)"
        }.joined(separator: "\n")
    }

    private static func anchorSnapshotText(_ anchor: LLMAnchorSnapshot?) -> String {
        guard let anchor, !anchor.text.isEmpty else {
            return "none"
        }

        if let note = anchor.note, !note.isEmpty {
            return "\"\(anchor.text)\" [note: \(note)]"
        }
        return "\"\(anchor.text)\""
    }

    private static func recallScaffoldText(
        _ scaffold: RecallPromptScaffold?,
        requestedMode: LLMRecallCardMode?
    ) -> String {
        guard let scaffold else { return "none" }

        var lines: [String] = []

        if let learnerCue = scaffold.learnerCue, !learnerCue.isEmpty {
            lines.append("- learner cue: \"\(learnerCue)\"")
        }
        if let hint = scaffold.hint, !hint.isEmpty {
            lines.append("- preferred hint: \"\(hint)\"")
        }

        return lines.isEmpty ? "none" : lines.joined(separator: "\n")
    }

    private static func recallLearningAidsText(_ context: LLMRecallGenerationContext) -> String {
        let sections: [(String, [String])] = [
            ("Pitfalls", context.acceptedPitfalls),
            ("Usage hints", context.acceptedUsageHints),
            ("Mnemonics", context.acceptedMnemonics),
            ("Collocations", context.acceptedCollocations)
        ]

        let rendered = sections.compactMap { title, values -> String? in
            let items = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "- \(title):\n" + items.map { "  - \($0)" }.joined(separator: "\n")
        }

        return rendered.isEmpty ? "none" : rendered.joined(separator: "\n")
    }

    private static func targetCharacterListText(for word: String) -> String {
        let characters = Array(word)
        guard !characters.isEmpty else { return "none" }
        return characters.enumerated().map { index, character in
            "\(index + 1): \(character)"
        }
        .joined(separator: "\n")
    }

    private static func learningAidAcceptedContextText(_ context: LLMLearningAidAcceptedContext) -> String {
        let sections: [(String, [String])] = [
            ("Pitfalls", context.acceptedPitfalls),
            ("Usage hints", context.acceptedUsageHints),
            ("Mnemonics", context.acceptedMnemonics),
            ("Collocations", context.acceptedCollocations)
        ]

        let rendered = sections.compactMap { title, values -> String? in
            let items = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !items.isEmpty else { return nil }
            return "- \(title):\n" + items.map { "  - \($0)" }.joined(separator: "\n")
        }

        return rendered.isEmpty ? "none" : rendered.joined(separator: "\n")
    }

    private static func learningAidContextXML(
        target: String,
        senses: [LLMSensePromptInput],
        acceptedContext: LLMLearningAidAcceptedContext,
        anchor: LLMAnchorSnapshot?
    ) -> String {
        let senseBody = senses.enumerated().map { index, sense in
            """
              <sense index="\(index + 1)">
                <part_of_speech>\(PromptText.xmlEscaped(sense.partOfSpeech))</part_of_speech>
                <definition>\(PromptText.xmlEscaped(sense.definition))</definition>\(sense.semanticHint.map { "\n            <semantic_hint>\(PromptText.xmlEscaped($0))</semantic_hint>" } ?? "")
              </sense>
            """
        }.joined(separator: "\n")

        let acceptedSections: [(String, [String])] = [
            ("pitfalls", acceptedContext.acceptedPitfalls),
            ("usage_hints", acceptedContext.acceptedUsageHints),
            ("mnemonics", acceptedContext.acceptedMnemonics),
            ("collocations", acceptedContext.acceptedCollocations)
        ]

        let acceptedBody = acceptedSections.map { tag, values in
            let items = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if items.isEmpty {
                return "    <\(tag)>none</\(tag)>"
            }

            let renderedItems = items.map { value in
                "      <item>\(PromptText.xmlEscaped(value))</item>"
            }.joined(separator: "\n")

            return [
                "    <\(tag)>",
                renderedItems,
                "    </\(tag)>"
            ].joined(separator: "\n")
        }.joined(separator: "\n")

        let anchorBody: String
        if let anchor, !anchor.text.isEmpty {
            let noteLine = anchor.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "\n      <note>\(PromptText.xmlEscaped(anchor.note!.trimmingCharacters(in: .whitespacesAndNewlines)))</note>"
                : ""
            anchorBody = """
                <anchor_snapshot>
                  <text>\(PromptText.xmlEscaped(anchor.text))</text>\(noteLine)
                </anchor_snapshot>
            """
        } else {
            anchorBody = "    <anchor_snapshot>none</anchor_snapshot>"
        }

        return [
            "<learning_aids_context>",
            "  <target>\(PromptText.xmlEscaped(target))</target>",
            "  <sense_inventory>",
            senseBody,
            "  </sense_inventory>",
            "  <accepted_learning_material>",
            acceptedBody,
            "  </accepted_learning_material>",
            anchorBody,
            "</learning_aids_context>"
        ].joined(separator: "\n")
    }

    private static func recallWordSignalsText(_ wordSignals: LLMRecallWordSignals) -> String {
        [
            "- isPhrase: \(wordSignals.isPhrase)",
            "- hasRepeatedLetters: \(wordSignals.hasRepeatedLetters)",
            "- hasConfusableVowelCluster: \(wordSignals.hasConfusableVowelCluster)"
        ].joined(separator: "\n")
    }

    private static func recallAllowedModesText(_ modes: [LLMRecallCardMode]) -> String {
        modes.map { "- \($0.rawValue)" }.joined(separator: "\n")
    }

    private static func recallModePriorText(_ modePrior: LLMRecallCardMode?) -> String {
        guard let modePrior else { return "none" }
        return "- suggested primary mode: \(modePrior.rawValue)"
    }

    private static func recallCardContractText(target: String, learnerCue: String? = nil) -> String {
        var lines = ["English target: \(target)"]
        if let learnerCue, !learnerCue.isEmpty {
            lines.append("Chinese learner cue: \(learnerCue)")
        }
        lines.append(contentsOf: [
            "front is the recall prompt",
            "back is the exact target answer",
            "front must not reveal the full back",
            "back must remain unchanged"
        ])
        return lines.joined(separator: "\n")
    }

    private static func recallModeSelectionContractText() -> String {
        PromptText.bulletList([
            "Choose the mode from the main learning bottleneck",
            "If the target is a phrase, choose phrase_recall",
            "If accepted pitfalls or word signals point to a local spelling hotspot, choose targeted_letter_cloze",
            "Otherwise choose full_spelling",
            "Treat repeated letters, confusing letter order, and confusable vowel clusters as local spelling hotspots",
            "If evidence is mixed, follow modePrior"
        ])
    }

    private static func recallNormalizedCueContractText() -> String {
        PromptText.bulletList([
            "normalizedCue must be semantic-only Chinese",
            "normalizedCue must stay short and learner-facing",
            "normalizedCue must not contain packaging text",
            "normalizedCue must not contain the English target",
            "normalizedCue must not contain underscores",
            "normalizedCue must not contain terms such as 拼出, 补全, 回忆, 完整英文单词, 完整英文词组"
        ])
    }

    private static func recallClozeRenderingContractText() -> String {
        PromptText.bulletList([
            "Hide exactly one internal spelling hotspot",
            "Use exactly one underscore group",
            "That group must contain 2 or 3 underscores",
            "Prefer a repeated-letter pair or confusable vowel cluster when available",
            "front = normalizedCue + maskedTarget",
            "Put maskedTarget in front, never in back"
        ])
    }

    private static func recallPlanExamplesText() -> String {
        """
        <plan_examples_do_not_copy>
          <example>
            <target>receive</target>
            <selectedMode>targeted_letter_cloze</selectedMode>
            <normalizedCue>收到</normalizedCue>
          </example>
          <example>
            <target>take off</target>
            <selectedMode>phrase_recall</selectedMode>
            <normalizedCue>飞机起飞</normalizedCue>
          </example>
          <example>
            <target>book</target>
            <selectedMode>full_spelling</selectedMode>
            <normalizedCue>书</normalizedCue>
          </example>
          <bad_cue>
            <normalizedCue>收到 · 拼出完整英文单词</normalizedCue>
            <reason>normalizedCue must be semantic only, not packaging text</reason>
          </bad_cue>
          <bad_cue>
            <normalizedCue>常见词语搭配 · co__ocation</normalizedCue>
            <reason>normalizedCue must not contain English target text or underscores</reason>
          </bad_cue>
        </plan_examples_do_not_copy>
        """
    }

    private static func recallDraftExamplesText(for mode: LLMRecallCardMode) -> String {
        switch mode {
        case .fullSpelling:
            return """
            <draft_examples_do_not_copy>
              <example mode="full_spelling">
                <target>receive</target>
                <normalizedCue>收到</normalizedCue>
                <front>收到 · 拼出完整英文单词</front>
                <back>receive</back>
              </example>
              <bad_front>
                <front>收到 · receive</front>
                <reason>front reveals the full back</reason>
              </bad_front>
            </draft_examples_do_not_copy>
            """
        case .targetedLetterCloze:
            return """
            <draft_examples_do_not_copy>
              <example mode="targeted_letter_cloze">
                <target>receive</target>
                <normalizedCue>收到</normalizedCue>
                <maskedTarget>rec__ve</maskedTarget>
                <front>收到 · rec__ve</front>
                <back>receive</back>
              </example>
              <example mode="targeted_letter_cloze">
                <target>collocation</target>
                <normalizedCue>常见词语搭配</normalizedCue>
                <maskedTarget>co__ocation</maskedTarget>
                <front>常见词语搭配 · co__ocation</front>
                <back>collocation</back>
              </example>
              <bad_front>
                <front>词语组合 · collocation</front>
                <reason>front reveals the full back</reason>
              </bad_front>
              <bad_draft>
                <front>i/e 顺序容易写反 · 拼出单词</front>
                <back>recei_ve</back>
                <reason>back must stay unmasked</reason>
              </bad_draft>
              <bad_front>
                <front>动词 · rece_ve</front>
                <reason>a one-underscore mask is invalid; use 2 or 3 underscores for the hotspot</reason>
              </bad_front>
            </draft_examples_do_not_copy>
            """
        case .phraseRecall:
            return """
            <draft_examples_do_not_copy>
              <example mode="phrase_recall">
                <target>take off</target>
                <normalizedCue>飞机起飞</normalizedCue>
                <front>飞机起飞 · 回忆完整英文词组</front>
                <back>take off</back>
              </example>
              <bad_front>
                <front>飞机起飞 · take off</front>
                <reason>front reveals the full back</reason>
              </bad_front>
            </draft_examples_do_not_copy>
            """
        }
    }

    private static func recallModeConstraintRules(_ modes: [LLMRecallCardMode]) -> [String] {
        guard modes.count == 1, let fixedMode = modes.first else {
            return []
        }

        return [
            "selectedMode must be \(fixedMode.rawValue)",
            "Do not consider any other mode"
        ]
    }
}
