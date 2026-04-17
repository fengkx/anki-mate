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
        let system = """
        You are a bilingual language learning assistant.
        Generate natural English example sentences with concise Chinese translations.
        Keep English at B1-B2 level and Chinese idiomatic.
        When multiple senses are provided, maximize semantic coverage before repeating a meaning.
        """

        let user = """
        Generate exactly \(desiredCount) natural English example sentences for the target word "\(word)".

        Sense inventory:
        \(senseInventoryText(from: trimmedSenses))

        Rules:
        - Prioritize a different meaning or part of speech on each line whenever the inventory allows it
        - If multiple senses are listed, cover every listed sense before repeating one
        - If only one sense is listed, you may generate up to 3 distinct contexts for that single sense
        - Use natural, everyday language
        - Each sentence should be 8-20 words
        - For each item, output in this format: English sentence — Chinese translation
        - Do not explain which sense you picked
        - Do not use bullets, numbering, labels, or extra markup
        - Return ONLY the \(desiredCount) plain lines
        """

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
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let desiredCount = usageHintCount(for: trimmedSenses)
        let system = """
        You are a bilingual language learning assistant.
        Summarize dictionary meanings into concise learner-friendly usage hints in both English and Chinese.
        """

        let user = """
        Write concise learner usage hints for the word "\(word)" using this sense inventory:

        \(senseInventoryText(from: trimmedSenses))

        Rules:
        - If multiple senses are listed, cover every listed sense before expanding on one
        - If only one sense is listed, write \(desiredCount) short lines that vary the usage cue or collocation
        - Use simple vocabulary
        - Focus on sense distinction, common usage cues, or memorable contrasts
        - Return exactly \(desiredCount) short plain lines
        - Output each line in this format:
          <learner-friendly explanation> — <中文解释/用法提示>
        - Do not use bullets, numbering, part-of-speech labels, EN/ZH labels, or extra markup
        - Return ONLY the lines
        """

        return (system, user)
    }

    public static func recallCardDrafts(
        word: String,
        senses: [LLMSensePromptInput],
        modes: [LLMRecallCardMode],
        anchor: LLMAnchorSnapshot? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses
        let requestedModes = modes.isEmpty ? LLMRecallCardMode.allCases : modes

        let system = """
        You are a bilingual language learning assistant.
        Generate recall-oriented flashcard drafts as strict JSON.
        Prefer concise learner-facing prompts, keep answers exact, and never add markdown fences or commentary.
        """

        let user = """
        Generate exactly \(requestedModes.count) recall card drafts for the target "\(trimmedWord)".

        Sense inventory:
        \(senseInventoryText(from: trimmedSenses))

        Requested modes:
        \(requestedModes.map { "- \($0.rawValue)" }.joined(separator: "\n"))

        Anchor snapshot:
        \(anchorSnapshotText(anchor))

        Rules:
        - Return a single JSON object with this shape:
          {
            "drafts": [
              {
                "mode": "full_spelling | targeted_letter_cloze | phrase_recall",
                "front": "learner-facing prompt",
                "back": "exact answer",
                "hint": "optional short hint or null",
                "anchor": { "text": "optional display snapshot", "note": "optional note" } | null
              }
            ]
          }
        - Output exactly one draft for each requested mode, no more and no fewer
        - front should be a recall cue, usually grounded in Chinese meaning, semantic hint, or learner instruction
        - back must be the exact target word or phrase, with original spacing preserved
        - For full_spelling, ask the learner to recall the complete target
        - For targeted_letter_cloze, hide the most error-prone letters with underscores in front or hint
        - For phrase_recall, focus on recalling the whole phrase or key phrase chunk naturally
        - hint is optional and should stay short
        - anchor is optional display metadata only; do not invent source offsets or remap anchors
        - If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null
        - Return JSON only
        """

        return (system, user)
    }

    public static func learningAids(
        word: String,
        senses: [LLMSensePromptInput],
        anchor: LLMAnchorSnapshot? = nil
    ) -> (system: String, user: String) {
        let trimmedWord = word.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSenses = senses.isEmpty
            ? [LLMSensePromptInput(partOfSpeech: "general", definition: "general usage")]
            : senses

        let system = """
        You are a bilingual language learning assistant.
        Generate strict JSON learning aids that help with recall, correct usage, and collocations.
        Keep every field concise and practical for flashcards.
        """

        let user = """
        Generate structured learning aids for the target "\(trimmedWord)".

        Sense inventory:
        \(senseInventoryText(from: trimmedSenses))

        Anchor snapshot:
        \(anchorSnapshotText(anchor))

        Return a single JSON object with this shape:
        {
          "pitfalls": [
            {
              "summary": "short learner warning",
              "details": "optional extra explanation",
              "anchor": { "text": "optional display snapshot", "note": "optional note" } | null
            }
          ],
          "mnemonics": [
            {
              "clue": "very short mnemonic cue",
              "anchor": { "text": "optional display snapshot", "note": "optional note" } | null
            }
          ],
          "collocations": [
            {
              "phrase": "common collocation or pattern",
              "gloss": "optional short usage gloss",
              "anchor": { "text": "optional display snapshot", "note": "optional note" } | null
            }
          ]
        }

        Rules:
        - Return JSON only
        - pitfalls: 2-4 items, focus on spelling traps, confusable meanings, or common misuse
        - mnemonics: 1-3 items, make them short and memorable rather than explanatory
        - collocations: 2-5 items, prefer high-frequency phrases or short patterns
        - Keep every string compact and learner-facing
        - anchor is optional display metadata only; do not invent source offsets or remap anchors
        - If an anchor snapshot is supplied and directly useful, you may copy it as-is or leave anchor null
        """

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
}
