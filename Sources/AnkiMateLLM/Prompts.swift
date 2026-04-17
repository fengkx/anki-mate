// Prompt templates for LLM-powered features.

import Foundation

public enum LLMPrompt {

    public static func exampleSentences(
        word: String,
        partOfSpeech: String,
        definition: String
    ) -> (system: String, user: String) {
        let system = """
        You are a bilingual language learning assistant.
        Generate natural English example sentences with concise Chinese translations.
        Keep English at B1-B2 level and Chinese idiomatic.
        """

        let user = """
        Generate 3 natural English example sentences using the word "\(word)" \
        as a \(partOfSpeech) with this meaning: \(definition)

        Rules:
        - Each sentence should demonstrate a different context
        - Use natural, everyday language
        - Each sentence should be 8-20 words
        - For each item, output in this format: English sentence — Chinese translation
        - Return ONLY the 3 lines, numbered 1-3
        """

        return (system, user)
    }

    public static func optimizeDefinition(
        word: String,
        rawDefinition: String
    ) -> (system: String, user: String) {
        let system = """
        You are a bilingual language learning assistant.
        Rewrite dictionary definitions to be clear and learner-friendly in both English and Chinese.
        """

        let user = """
        Rewrite this dictionary definition to be clearer for a language learner:

        Word: \(word)
        Original definition: \(rawDefinition)

        Rules:
        - Keep it concise (1-2 short lines)
        - Use simple vocabulary
        - Include usage hint if helpful
        - Output exactly two lines:
          EN: <learner-friendly explanation>
          ZH: <中文解释/用法提示>
        - Return ONLY these two lines
        """

        return (system, user)
    }
}
