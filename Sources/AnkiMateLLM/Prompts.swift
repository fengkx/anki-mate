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

    public static func optimizeDefinition(
        word: String,
        rawDefinition: String
    ) -> (system: String, user: String) {
        optimizeDefinition(
            word: word,
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "general",
                    definition: rawDefinition
                )
            ]
        )
    }

    public static func optimizeDefinition(
        word: String,
        senses: [LLMSensePromptInput]
    ) -> (system: String, user: String) {
        usageHints(
            word: word,
            senses: senses
        )
    }

    static func legacyOptimizeDefinitionText(
        word: String,
        senses: [LLMSensePromptInput]
    ) -> (system: String, user: String) {
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let desiredCount = usageHintCount(for: trimmedSenses)
        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Summarize dictionary meanings into concise learner-friendly usage hints in both English and Chinese."
        ])

        let user = PromptText.join([
            #"Write concise learner usage hints for the word "\#(word)" using this sense inventory:"#,
            senseInventoryText(from: trimmedSenses),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "If multiple senses are listed, cover every listed sense before expanding on one",
                    "If only one sense is listed, write \(desiredCount) short lines that vary the usage cue",
                    "Use simple vocabulary",
                    "Focus on sense distinction, common usage cues, or memorable contrasts",
                    "Do not write spelling warnings, confusable-word alerts, collocation lists, mnemonic slogans, or example sentences",
                    "Return exactly \(desiredCount) short plain lines",
                    "Output each line in this format:",
                    "<learner-friendly explanation> — <中文解释/用法提示>",
                    "Do not use bullets, numbering, part-of-speech labels, EN/ZH labels, or extra markup",
                    "Return ONLY the lines"
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
            "Focus on how the word is typically understood or used, and never add markdown fences or commentary."
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
                    "Do not output spelling warnings, confusable-word alerts, collocation lists, mnemonic slogans, example sentences, or dictionary-definition rewrites",
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
                    "front should be a recall cue, usually grounded in Chinese meaning, semantic hint, or learner instruction",
                    "back must be the exact target word or phrase, with original spacing preserved",
                    "For full_spelling, ask the learner to recall the complete target",
                    "For targeted_letter_cloze, choose the gap position yourself",
                    "For targeted_letter_cloze, use exactly one continuous underscore gap, and keep a Chinese meaning cue in front",
                    "For targeted_letter_cloze, the number of underscores must exactly match the number of hidden letters, for example lemma_ize hides one letter and le__atize hides two",
                    "For targeted_letter_cloze, prefer hiding at least two letters when that still forms a natural spelling hotspot; use one underscore only when one hidden letter is the best target",
                    "For targeted_letter_cloze, prefer internal spelling hotspots such as repeated consonants, confusable vowel clusters, or unstable suffix fragments",
                    "For targeted_letter_cloze, do not default to masking the first letter and do not make the card feel like a puzzle",
                    "For phrase_recall, focus on recalling the whole phrase or key phrase chunk naturally",
                    "If a learner cue is provided above, use it as the semantic basis of the front instead of drifting to another explanation",
                    "If a short hint is provided above, prefer reusing or lightly polishing it rather than inventing a long hint",
                    "hint is optional and should stay short",
                    "anchor is optional display metadata only; do not invent source offsets or remap anchors",
                    "If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null",
                    "This is a single-draft workspace contract, not a multi-mode batch response",
                    "Do not emit alternative modes, numbered options, explanations, or extra fields"
                ])
            )
        ])

        return (system, user)
    }

    public static func recallCardDrafts(
        word: String,
        senses: [LLMSensePromptInput],
        modes: [LLMRecallCardMode],
        anchor: LLMAnchorSnapshot? = nil
    ) -> (system: String, user: String) {
        recallCardDraft(
            word: word,
            senses: senses,
            requestedMode: modes.first ?? .fullSpelling,
            anchor: anchor
        )
    }

    public static func recallCardDecision(
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

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Generate exactly one recall-oriented flashcard draft as strict structured JSON.",
            "Choose the most appropriate recall mode from the allowed modes.",
            "Base the choice on accepted learning aids, sense inventory, and the main learning objective.",
            "When raw dictionary wording is technical, formal, or mixed with romanization, rewrite it into plain learner-facing Chinese before drafting the card.",
            "Never add markdown fences, commentary, or extra fields."
        ])

        let user = PromptText.join([
            #"Generate exactly 1 recall card draft for the target "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Accepted learning aids", value: recallLearningAidsText(context)),
            PromptText.labeledBlock("Word signals", value: recallWordSignalsText(wordSignals)),
            PromptText.labeledBlock("Allowed modes", value: recallAllowedModesText(normalizedModes)),
            PromptText.labeledBlock("Mode prior", value: recallModePriorText(modePrior)),
            PromptText.labeledBlock("Anchor snapshot", value: anchorSnapshotText(anchor)),
            PromptText.labeledBlock("Packaging scaffold", value: recallScaffoldText(scaffold, requestedMode: nil)),
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"draft\": {",
                "    \"mode\": \"full_spelling | targeted_letter_cloze | phrase_recall\",",
                "    \"front\": \"learner-facing prompt\",",
                "    \"back\": \"exact answer\",",
                "    \"hint\": \"optional short hint or null\",",
                "    \"anchor\": { \"text\": \"optional display snapshot\", \"note\": \"optional note\" } | null",
                "  },",
                "  \"selectionReason\": {",
                "    \"primaryGoal\": \"whole_word_recall | local_spelling_calibration | phrase_chunk_retrieval\",",
                "    \"evidence\": [\"short reason 1\", \"short reason 2\"]",
                "  },",
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
                    "Before writing front, choose one semantic source and rewrite it into a learner-facing cue",
                    "Write cuePlan first, then write draft.front as the final rendered version of cuePlan.normalizedCue",
                    "draft.front must be derived from cuePlan.normalizedCue, not independently rewritten from raw sources",
                    "mode must be one of the allowed modes",
                    "Choose one main learning objective first, then choose the mode",
                    "Use accepted pitfalls, accepted usage hints, and sense inventory as the primary basis for mode selection",
                    "When accepted usage hints provide a cleaner learner-facing meaning than the raw sense inventory, prefer the accepted usage hints as the semantic source for front and hint",
                    "Treat raw sense inventory mainly as reference or disambiguation when it is more technical, more formal, or noisier than the accepted usage hints",
                    "Use word signals only as supporting evidence, not as a replacement for semantic judgment",
                    "Do not choose targeted_letter_cloze only because the word is long or has a maskable segment",
                    "front should be a concise recall cue, usually grounded in Chinese meaning, semantic hint, or learner instruction",
                    "Prefer plain learner-friendly Chinese over copied dictionary jargon when a simpler paraphrase is available",
                    "If the sense inventory contains dictionary jargon, formal gloss wording, or bilingual fragments, rewrite the meaning into natural learner-facing Chinese instead of quoting it",
                    "Do not copy pinyin, romanization, or pronunciation respelling into front or hint",
                    "If any source line contains pinyin, romanization, or mixed bilingual gloss text, strip those parts and keep only the learner-facing Chinese meaning",
                    "back must be the exact target word or phrase, with original spacing preserved",
                    "Use accepted usage hints to sharpen the Chinese cue, not to write a long explanation",
                    "Use mnemonics only for a very short hint when useful",
                    "Do not dump pitfalls, usage hints, and collocations into the front",
                    "hint is optional and should stay short",
                    "selectionReason is required and evidence must be short, concrete, and non-empty",
                    "cuePlan is required and must explain which semantic source you used before writing the final front",
                    "normalizedCue must be a short learner-facing cue, not copied raw dictionary wording",
                    "After cuePlan is chosen, do not introduce new dictionary jargon, romanization, or technical wording that is absent from normalizedCue",
                    "For full_spelling, ask the learner to recall the complete target",
                    "For phrase_recall, focus on recalling the whole phrase or key phrase chunk naturally",
                    "For targeted_letter_cloze, choose the gap position yourself",
                    "For targeted_letter_cloze, use exactly one continuous underscore gap",
                    "For targeted_letter_cloze, the number of underscores must exactly match the number of hidden letters, for example lemma_ize hides one letter and le__atize hides two",
                    "For targeted_letter_cloze, prefer hiding at least two letters when that still forms a natural spelling hotspot; use one underscore only when one hidden letter is the best target",
                    "For targeted_letter_cloze, prefer internal spelling hotspots such as repeated consonants, confusable vowel clusters, or unstable suffix fragments",
                    "For targeted_letter_cloze, do not default to masking the first letter",
                    "For targeted_letter_cloze, keep a clear Chinese cue on the front and do not make the card feel like a puzzle",
                    "If accepted pitfalls point to a local spelling risk, align the gap with that risk when possible",
                    "anchor is optional display metadata only; do not invent source offsets or remap anchors",
                    "If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null",
                    "Return exactly one draft only"
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

        let system = PromptText.join([
            "You are a bilingual language learning assistant.",
            "Plan exactly one recall-oriented flashcard as strict structured JSON.",
            "Choose the most appropriate recall mode from the allowed modes.",
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
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"selectedMode\": \"full_spelling | targeted_letter_cloze | phrase_recall\",",
                "  \"selectionReason\": {",
                "    \"primaryGoal\": \"whole_word_recall | local_spelling_calibration | phrase_chunk_retrieval\",",
                "    \"evidence\": [\"short reason 1\", \"short reason 2\"]",
                "  },",
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
                    "Choose one main learning objective first, then choose the mode",
                    "selectedMode must be one of the allowed modes",
                    "Use accepted pitfalls, accepted usage hints, and sense inventory as the primary basis for mode selection",
                    "Prefer accepted usage hints over raw sense inventory when they provide a cleaner learner-facing cue",
                    "When accepted usage hints provide a cleaner learner-facing meaning than the raw sense inventory, prefer the accepted usage hints as the semantic source",
                    "Treat raw sense inventory mainly as reference or disambiguation when it is more technical, more formal, or noisier than the accepted usage hints",
                    "Use word signals only as supporting evidence, not as a replacement for semantic judgment",
                    "Do not choose targeted_letter_cloze only because the word is long or has a maskable segment",
                    "cuePlan is required and must explain which semantic source you used",
                    "Even when only one mode is allowed, still choose cuePlan first and normalize the semantic cue before packaging the draft",
                    "normalizedCue must be a short learner-facing cue, not copied raw dictionary wording",
                    "Prefer plain learner-friendly Chinese over copied dictionary jargon when a simpler paraphrase is available",
                    "If the sense inventory contains dictionary jargon, formal gloss wording, or bilingual fragments, rewrite the meaning into natural learner-facing Chinese instead of quoting it",
                    "Do not let a forced mode justify copying dictionary jargon, formal gloss wording, or bilingual fragments into normalizedCue",
                    "Do not copy pinyin, romanization, or pronunciation respelling into normalizedCue",
                    "If any source line contains pinyin, romanization, or mixed bilingual gloss text, strip those parts and keep only the learner-facing Chinese meaning",
                    "If the forced mode is targeted_letter_cloze, keep the Chinese cue natural and conversational before adding the gap",
                    "normalizedCue must not contain the exact target word or phrase",
                    "selectionReason is required and evidence must be short, concrete, and non-empty",
                    "Return exactly one plan only"
                ])
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
                    "draft.front must be derived from normalizedCue, not independently rewritten from raw sources",
                    "Do not introduce new dictionary jargon, romanization, or technical wording that is absent from normalizedCue",
                    "Do not copy pinyin, romanization, or pronunciation respelling into front or hint",
                    "back must be the exact target word or phrase, with original spacing preserved",
                    "hint is optional and should stay short",
                    "For full_spelling, ask the learner to recall the complete target",
                    "For phrase_recall, focus on recalling the whole phrase or key phrase chunk naturally",
                    "For targeted_letter_cloze, choose the gap position yourself",
                    "For targeted_letter_cloze, use exactly one continuous underscore gap",
                    "For targeted_letter_cloze, the number of underscores must exactly match the number of hidden letters, for example lemma_ize hides one letter and le__atize hides two",
                    "For targeted_letter_cloze, prefer hiding at least two letters when that still forms a natural spelling hotspot; use one underscore only when one hidden letter is the best target",
                    "For targeted_letter_cloze, prefer internal spelling hotspots such as repeated consonants, confusable vowel clusters, or unstable suffix fragments",
                    "For targeted_letter_cloze, do not default to masking the first letter",
                    "For targeted_letter_cloze, keep the front natural as a learner-facing Chinese cue first, then add the gap",
                    "For targeted_letter_cloze, keep a clear Chinese cue on the front and do not make the card feel like a puzzle",
                    "anchor is optional display metadata only; do not invent source offsets or remap anchors",
                    "If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null",
                    "Return exactly one draft only"
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
            "If a section does not contain that level of value, return an empty array.",
            "Prefer omission over low-information correctness.",
            "Keep every field concise and practical for flashcards.",
            "Use accepted learning material as already-covered teaching points and avoid repeating them. Accepted material may be in Chinese or English; concept overlap still counts.",
            "Prefer returning fewer, stronger items over filling every section with weak content."
        ])

        let user = PromptText.join([
            #"Generate structured learning aids for the target "\#(trimmedWord)"."#,
            PromptText.labeledBlock("Sense inventory", value: senseInventoryText(from: trimmedSenses)),
            PromptText.labeledBlock("Accepted learning material", value: learningAidAcceptedContextText(acceptedContext)),
            PromptText.labeledBlock("Anchor snapshot", value: anchorSnapshotText(anchor)),
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
                "      \"kind\": \"sound_hook | image_hook | spelling_hook | contrast_hook\",",
                "      \"focus\": \"memory_hook | spelling_segment | meaning_contrast\",",
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
                    "mnemonics: require a vivid image, a concrete spelling chunk, or a memorable contrast that still works without seeing the headword",
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
                    "Bad mnemonic: reluctant -> \"Think of a person who is hesitant to agree\"",
                    "Bad pitfall: fragile -> \"Means weak or delicate\"",
                    "Bad collocation: principal -> \"principal of the school\"",
                    "Bad collocation: dismantle -> \"dismantle a machine\"",
                    "Why bad: these are too obvious from the core meaning or just restate the dictionary sense",
                    "If accepted pitfalls already include \"easy to miss the double l\", return an empty pitfall unless you have a genuinely different risk",
                    "If accepted collocations already include \"strong collocation\", do not output it again"
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
        strictSpellingRetry: Bool = false
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

        let retryReminder = strictSpellingRetry
            ? PromptText.join([
                "Retry correction:",
                "Your previous stressSyllables value did not preserve the original written spelling.",
                "This time, copy the original word's letters exactly and only insert hyphens plus uppercase emphasis."
            ])
            : nil

        let user = PromptText.join([
            #"Generate pronunciation enhancement data for the target word "\#(trimmedWord)"."#,
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
            retryReminder,
            PromptText.jsonBlock([
                "Return a single JSON object with this shape:",
                "{",
                "  \"ipa\": \"pure IPA only or null\",",
                "  \"stressSyllables\": \"hyphen-joined syllables with the primary-stress syllable uppercased\"",
                "}"
            ]),
            PromptText.labeledBlock(
                "Rules",
                value: PromptText.bulletList([
                    "Output JSON only",
                    "\"stressSyllables\" is required",
                    "Split the original written word into learner-friendly chunks joined by hyphens",
                    "Preserve the original spelling exactly; do not rewrite letters to match pronunciation",
                    "After removing hyphens and case markers, the result must still spell the original word",
                    "For multisyllable words, uppercase the primary-stress syllable only, for example \"im-POR-tant\"",
                    "Prefer spelling-aware chunks like \"aes-THET-ic\" over pronunciation-only rewrites like \"es-THET-ic\"",
                    "For monosyllable words, return the plain word only, for example \"flock\"",
                    "If the dialect has multiple accepted variants, choose one default variant and return one string only",
                    "Do not include spaces, labels, bullets, markdown, commentary, alternatives, slashes, commas, or \"or\"",
                    "If existing IPA is already provided, keep \"ipa\" as null unless correction is necessary",
                    "If \"ipa\" is present, it must be a single IPA string without slashes",
                    "Do not return respelling notation such as SH, TH, CH, or uppercase helper text as IPA",
                    "Prefer the requested dialect if one is provided",
                    "Use the pronunciation guide as a hint only; correct it into real IPA when needed"
                ])
            )
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
}
