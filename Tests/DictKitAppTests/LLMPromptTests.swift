import XCTest
@testable import AnkiMateLLM

final class LLMPromptTests: XCTestCase {
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

    func testUsagePromptUsesTwoLinesForSingleSense() {
        let prompt = LLMPrompt.optimizeDefinition(
            word: "perpetual",
            senses: [
                LLMSensePromptInput(
                    partOfSpeech: "adjective",
                    definition: "never ending or changing"
                )
            ]
        )

        XCTAssertTrue(prompt.user.contains("write 2 short lines"))
        XCTAssertTrue(prompt.user.contains("Return exactly 2 short plain lines"))
        XCTAssertTrue(prompt.user.contains("Do not use bullets, numbering, part-of-speech labels, EN/ZH labels, or extra markup"))
    }

    func testUsagePromptUsesOneLinePerSenseWhenMultipleSensesExist() {
        let senses = [
            LLMSensePromptInput(partOfSpeech: "noun", definition: "formal accusation"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "ask someone to pay a price"),
            LLMSensePromptInput(partOfSpeech: "verb", definition: "fill a battery")
        ]

        let prompt = LLMPrompt.optimizeDefinition(word: "charge", senses: senses)

        XCTAssertTrue(prompt.user.contains("Return exactly 3 short plain lines"))
        XCTAssertTrue(prompt.user.contains("cover every listed sense before expanding on one"))
        XCTAssertTrue(prompt.user.contains("1. noun: formal accusation"))
        XCTAssertTrue(prompt.user.contains("2. verb: ask someone to pay a price"))
        XCTAssertTrue(prompt.user.contains("3. verb: fill a battery"))
    }
}
