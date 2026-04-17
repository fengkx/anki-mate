// Prompt templates for LLM-powered features.

import Foundation

public enum LLMPrompt {

    public static func exampleSentences(
        word: String,
        partOfSpeech: String,
        definition: String
    ) -> (system: String, user: String) {
        let system = """
        You are a language learning assistant. Generate natural English example sentences \
        that help learners understand vocabulary in context. Use clear, everyday language \
        at B1-B2 level.
        """

        let user = """
        Generate 3 natural English example sentences using the word "\(word)" \
        as a \(partOfSpeech) with this meaning: \(definition)

        Rules:
        - Each sentence should demonstrate a different context
        - Use natural, everyday language
        - Each sentence should be 8-20 words
        - Return ONLY the sentences, one per line, numbered 1-3
        """

        return (system, user)
    }

    public static func optimizeDefinition(
        word: String,
        rawDefinition: String
    ) -> (system: String, user: String) {
        let system = """
        You are a language learning assistant. Your task is to rewrite dictionary definitions \
        to be clearer and more helpful for language learners.
        """

        let user = """
        Rewrite this dictionary definition to be clearer for a language learner:

        Word: \(word)
        Original definition: \(rawDefinition)

        Rules:
        - Keep it concise (1-2 sentences)
        - Use simple vocabulary
        - Include a brief note about common usage if helpful
        - Return ONLY the improved definition, nothing else
        """

        return (system, user)
    }
}
