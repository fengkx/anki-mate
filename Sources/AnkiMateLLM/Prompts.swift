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

    private static func senseInventoryText(from senses: [LLMSensePromptInput]) -> String {
        guard !senses.isEmpty else {
            return "1. general: no sense inventory provided"
        }

        return senses.enumerated().map { index, sense in
            "\(index + 1). \(sense.inventoryLine)"
        }.joined(separator: "\n")
    }
}
