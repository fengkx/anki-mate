import DictKit
import DictKitAnkiExport
import Foundation
import XCTest

final class AnkiFieldFormatterTests: XCTestCase {
    func testPhoneticExtraction() {
        let result = makeLookupResult(
            word: "apple",
            pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)]
        )
        XCTAssertEqual(AnkiFieldFormatter.phonetic(from: result), "ˈæpəl")
    }

    func testPhoneticFallsBackToLexicalEntry() {
        let result = makeLookupResult(
            word: "test",
            pronunciations: [],
            lexicalPronunciations: [Pronunciation(dialect: nil, ipa: "tɛst", respelling: nil)]
        )
        XCTAssertEqual(AnkiFieldFormatter.phonetic(from: result), "tɛst")
    }

    func testPhoneticReturnsEmptyWhenNone() {
        let result = makeLookupResult(word: "unknown", pronunciations: [])
        XCTAssertEqual(AnkiFieldFormatter.phonetic(from: result), "")
    }

    func testDefinitionsHTMLContainsPOS() {
        let result = makeLookupResult(
            word: "run",
            pronunciations: [],
            senses: [("verb", "move at a speed faster than a walk", ["she ran to the door"])]
        )
        let html = AnkiFieldFormatter.definitionsHTML(from: result)
        XCTAssertTrue(html.contains("verb"))
        XCTAssertTrue(html.contains("move at a speed faster than a walk"))
        XCTAssertTrue(html.contains("she ran to the door"))
    }

    func testDefinitionsHTMLEscapesSpecialChars() {
        let result = makeLookupResult(
            word: "test",
            pronunciations: [],
            senses: [("noun", "a <b>bold</b> & \"quoted\" definition", [])]
        )
        let html = AnkiFieldFormatter.definitionsHTML(from: result)
        XCTAssertTrue(html.contains("&lt;b&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
        XCTAssertTrue(html.contains("&quot;"))
    }

    func testRenderCardHTMLFront() {
        let note = AnkiNoteData(
            word: "apple",
            phonetic: "ˈæpəl",
            definitions: "<div>test</div>",
            audioFilename: nil,
            audioData: nil
        )
        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: false)
        XCTAssertTrue(html.contains("apple"))
        XCTAssertTrue(html.contains("ˈæpəl"))
        XCTAssertFalse(html.contains("<div>test</div>"))
    }

    func testRenderCardHTMLBack() {
        let note = AnkiNoteData(
            word: "apple",
            phonetic: "ˈæpəl",
            definitions: "<div>test</div>",
            audioFilename: nil,
            audioData: nil
        )
        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: true)
        XCTAssertTrue(html.contains("apple"))
        XCTAssertTrue(html.contains("<div>test</div>"))
        XCTAssertTrue(html.contains("hr id=\"answer\""))
    }

    func testRenderCardHTMLBackIncludesExampleMarkup() {
        let result = makeLookupResult(
            word: "apple",
            pronunciations: [Pronunciation(dialect: "AmE", ipa: "ˈæpəl", respelling: nil)],
            senses: [("noun", "fruit", ["I had an apple for lunch"])]
        )
        let note = AnkiNoteData(
            word: "apple",
            phonetic: AnkiFieldFormatter.phonetic(from: result),
            definitions: AnkiFieldFormatter.definitionsHTML(from: result),
            audioFilename: nil,
            audioData: nil
        )

        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: true)

        XCTAssertTrue(html.contains("I had an apple for lunch"))
        XCTAssertTrue(html.contains("examples"))
    }

    func testPhoneticDisplayAppendsPreferredStressSyllablesOnSecondLine() {
        let result = makeLookupResult(
            word: "aesthetic",
            pronunciations: [Pronunciation(dialect: "AmE", ipa: "ɛsˈθɛtɪk", respelling: nil)]
        )

        let display = AnkiFieldFormatter.phoneticDisplay(
            from: result,
            aiArtifacts: AIArtifacts(generatedStressSyllablesByDialect: ["AmE": "aes-THET-ic"])
        )

        XCTAssertEqual(display, "/ɛsˈθɛtɪk/\naes-THET-ic")
    }

    func testRenderCardHTMLPreservesLineBreaksInPhoneticField() {
        let note = AnkiNoteData(
            word: "aesthetic",
            phonetic: "/ɛsˈθɛtɪk/\naes-THET-ic",
            definitions: "<div>test</div>",
            audioFilename: nil,
            audioData: nil
        )

        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: false)

        XCTAssertTrue(html.contains("/ɛsˈθɛtɪk/<br>aes-THET-ic"))
    }

    func testRenderRecallCardHTMLIncludesAnswerPronunciationAndAISupplementsOnBack() {
        let note = AnkiNoteData(
            recallPrompt: "(combining) • co__ocation",
            recallMode: "Targeted Letter Cloze",
            recallInstruction: "Rebuild the missing spelling segment instead of just recognizing the word.",
            recallHint: "noun • (combining)",
            recallAnswerHTML: "collocation",
            sourceWord: "collocation",
            phonetic: "/ˌkɒləˈkeɪʃən/<br>col-LO-ca-tion",
            definitionsHTML: """
            <section class="ai-study-layer">
              <div class="ai-study-title">Memory-focused notes</div>
              <div class="ai-example-grid"><div class="ai-example-card">example</div></div>
            </section>
            """,
            audioFilename: "collocation.wav",
            audioData: Data([0x01]),
            sortField: "collocation",
            guidSeed: "collocation|recall"
        )

        let html = AnkiFieldFormatter.renderCardHTML(note: note, showBack: true)

        XCTAssertTrue(html.contains("Targeted Letter Cloze"))
        XCTAssertTrue(html.contains("Back"))
        XCTAssertTrue(html.contains("collocation"))
        XCTAssertTrue(html.contains("Source Entry"))
        XCTAssertTrue(html.contains("Reference"))
        XCTAssertTrue(html.contains("/ˌkɒləˈkeɪʃən/<br>col-LO-ca-tion"))
        XCTAssertTrue(html.contains("[sound:collocation.wav]"))
        XCTAssertTrue(html.contains("ai-study-layer"))
        XCTAssertTrue(html.contains("ai-example-grid"))
    }

    func testCardTemplatesIncludeNightModeThemeOverrides() {
        XCTAssertTrue(AnkiCardTemplate.css.contains(".nightMode.card"))
        XCTAssertTrue(AnkiCardTemplate.css.contains("--card-bg"))
        XCTAssertTrue(AnkiRecallCardTemplate.css.contains(".nightMode.card"))
        XCTAssertTrue(AnkiRecallCardTemplate.css.contains("--answer-blue"))
    }

    func testDefinitionsHTMLIntegratesAcceptedAIContentWithoutLegacyHeadings() {
        let result = makeLookupResult(
            word: "lemmatize",
            pronunciations: [],
            senses: [("verb", "reduce to base form", ["We lemmatize the tokens before analysis."])]
        )

        let html = AnkiFieldFormatter.definitionsHTML(
            from: result,
            aiAcceptedExampleSentences: ["Before analysis, we need to lemmatize the words carefully."],
            aiAcceptedDefinitionNote: "EN: Reduce inflected forms to their base form."
        )

        XCTAssertTrue(html.contains("Before analysis, we need to lemmatize the words carefully."))
        XCTAssertTrue(html.contains("EN: Reduce inflected forms to their base form."))
        XCTAssertTrue(html.contains("AI-generated"))
        XCTAssertFalse(html.contains("AI Examples"))
        XCTAssertFalse(html.contains("AI Usage"))
    }

    func testDefinitionsHTMLPreservesLineBreaksInAcceptedUsageHint() {
        let result = makeLookupResult(
            word: "charge",
            pronunciations: [],
            senses: [("verb", "ask someone to pay a price", [])]
        )

        let html = AnkiFieldFormatter.definitionsHTML(
            from: result,
            aiAcceptedDefinitionNote: "- [verb] EN: ask for payment | ZH: 索费\n- [verb] EN: fill a battery | ZH: 充电"
        )

        XCTAssertTrue(html.contains("<br>"))
        XCTAssertTrue(html.contains("fill a battery"))
    }

    func testAIArtifactsDefinitionsHTMLRendersUnifiedArtifactSections() {
        let result = makeLookupResult(
            word: "consensus",
            pronunciations: [],
            senses: [("noun", "general agreement", [])]
        )

        let html = AnkiFieldFormatter.definitionsHTML(
            from: result,
            aiArtifacts: AIArtifacts(
                recallCardDrafts: AIArtifactSlot(
                    accepted: [RecallCardDraft(mode: .phraseRecall, front: "reach a ____", back: "consensus", hint: "noun")]
                ),
                pitfalls: AIArtifactSlot(
                    accepted: [PitfallArtifact(text: "Do not confuse it with consent.")]
                ),
                mnemonics: AIArtifactSlot(
                    accepted: [MnemonicArtifact(text: "Consensus sounds like many voices settling down.")]
                ),
                collocations: AIArtifactSlot(
                    accepted: [CollocationArtifact(phrase: "reach a consensus", note: "very common academic usage")]
                )
            )
        )

        XCTAssertTrue(html.contains("Learning Aids"))
        XCTAssertTrue(html.contains("Do not confuse it with consent."))
        XCTAssertTrue(html.contains("Consensus sounds like many voices settling down."))
        XCTAssertTrue(html.contains("reach a consensus"))
        XCTAssertTrue(html.contains("AI-generated"))
    }

    func testDefinitionsHTMLRendersExampleCardsAndGroupedLearningAids() {
        let result = makeLookupResult(
            word: "lemmatize",
            pronunciations: [],
            senses: [("verb", "reduce a word to its base form", [])]
        )

        let html = AnkiFieldFormatter.definitionsHTML(
            from: result,
            aiArtifacts: AIArtifacts(
                exampleSentences: AIArtifactSlot(
                    accepted: [
                        ExampleSentenceArtifact(
                            text: "The software helps lemmatize noisy text before indexing. — 软件会在索引前先把噪声文本还原词形。"
                        )
                    ]
                ),
                definitionNote: AIArtifactSlot(
                    accepted: DefinitionNoteArtifact(text: "Use this when you want the base form, not the inflected surface form.")
                ),
                pitfalls: AIArtifactSlot(
                    accepted: [PitfallArtifact(text: "Do not confuse the verb with its infinitive label.")]
                ),
                mnemonics: AIArtifactSlot(
                    accepted: [MnemonicArtifact(text: "Lemma = base form.")]
                ),
                collocations: AIArtifactSlot(
                    accepted: [CollocationArtifact(phrase: "lemmatize text", note: "common NLP wording")]
                )
            )
        )

        XCTAssertTrue(html.contains("ai-study-layer"))
        XCTAssertTrue(html.contains("Memory-focused notes"))
        XCTAssertTrue(html.contains("ai-example-grid"))
        XCTAssertTrue(html.contains("The software helps lemmatize noisy text before indexing."))
        XCTAssertTrue(html.contains("软件会在索引前先把噪声文本还原词形。"))
        XCTAssertTrue(html.contains("Learning Aids"))
        XCTAssertTrue(html.contains("common NLP wording"))
    }

    func testAIArtifactsDefinitionsHTMLRendersEmptyAcceptedArtifactSectionsAsOmitted() {
        let result = makeLookupResult(
            word: "consensus",
            pronunciations: [],
            senses: [("noun", "general agreement", [])]
        )

        let html = AnkiFieldFormatter.definitionsHTML(
            from: result,
            aiArtifacts: AIArtifacts(
                recallCardDrafts: AIArtifactSlot(accepted: []),
                pitfalls: AIArtifactSlot(accepted: []),
                mnemonics: AIArtifactSlot(accepted: []),
                collocations: AIArtifactSlot(accepted: [])
            )
        )

        XCTAssertFalse(html.contains("Pitfalls"))
        XCTAssertFalse(html.contains("Mnemonics"))
        XCTAssertFalse(html.contains("Collocations"))
    }

    func testAIArtifactsDefinitionsHTMLEscapesArtifactContentAndKeepsModeLabels() {
        let result = makeLookupResult(
            word: "consensus",
            pronunciations: [],
            senses: [("noun", "general agreement", [])]
        )

        let html = AnkiFieldFormatter.definitionsHTML(
            from: result,
            aiArtifacts: AIArtifacts(
                recallCardDrafts: AIArtifactSlot(
                    accepted: [
                        RecallCardDraft(
                            mode: .targetedLetterCloze,
                            front: "reach a <blank>",
                            back: "consensus",
                            hint: "use <c>"
                        )
                    ]
                ),
                pitfalls: AIArtifactSlot(
                    accepted: [PitfallArtifact(text: "Do not confuse <consent> with consensus & agreement.")]
                ),
                mnemonics: AIArtifactSlot(
                    accepted: [MnemonicArtifact(text: "Think of many voices saying \"yes\".")]
                ),
                collocations: AIArtifactSlot(
                    accepted: [CollocationArtifact(phrase: "reach a consensus", note: "common <academic> usage")]
                )
            )
        )

        XCTAssertFalse(html.contains("Recall Cards"))
        XCTAssertTrue(html.contains("&lt;consent&gt;"))
        XCTAssertTrue(html.contains("&amp; agreement"))
        XCTAssertTrue(html.contains("&quot;yes&quot;"))
        XCTAssertTrue(html.contains("common &lt;academic&gt; usage"))
    }

    func testDefinitionsHTMLUsesStabilizedExampleArtifactSemantics() throws {
        let result = makeLookupResult(
            word: "analysis",
            pronunciations: [],
            senses: [("noun", "careful examination", [])]
        )
        let artifacts = try JSONDecoder().decode(
            AIArtifacts.self,
            from: Data(
                """
                {
                  "schemaVersion": 1,
                  "exampleSentences": {
                    "accepted": [
                      {
                        "text": "Before the meeting — 会前准备",
                        "translation": "stale translation"
                      },
                      {
                        "text": "After the review",
                        "translation": "复盘后"
                      }
                    ]
                  }
                }
                """.utf8
            )
        )

        let html = AnkiFieldFormatter.definitionsHTML(from: result, aiArtifacts: artifacts)

        XCTAssertTrue(html.contains("Before the meeting"))
        XCTAssertTrue(html.contains("会前准备"))
        XCTAssertTrue(html.contains("After the review"))
        XCTAssertTrue(html.contains("复盘后"))
        XCTAssertFalse(html.contains("stale translation"))
    }

    // MARK: - Helpers

    private func makeLookupResult(
        word: String,
        pronunciations: [Pronunciation],
        lexicalPronunciations: [Pronunciation] = [],
        senses: [(String, String, [String])] = []
    ) -> LookupResult {
        let lexEntries: [LexicalEntry] = senses.isEmpty
            ? [LexicalEntry(
                partOfSpeech: .noun,
                partOfSpeechLabel: "noun",
                displayIndex: 0,
                pronunciations: lexicalPronunciations,
                senses: [Sense(number: 1, semanticHint: nil, definition: "test", examples: [], registers: [], countability: nil)],
                grammar: [],
                inflections: []
            )]
            : senses.enumerated().map { i, s in
                LexicalEntry(
                    partOfSpeech: PartOfSpeech(rawValue: s.0) ?? .other,
                    partOfSpeechLabel: s.0,
                    displayIndex: i,
                    pronunciations: lexicalPronunciations,
                    senses: [Sense(number: 1, semanticHint: nil, definition: s.1, examples: s.2, registers: [], countability: nil)],
                    grammar: [],
                    inflections: []
                )
            }

        return LookupResult(
            query: word,
            entries: [HeadwordEntry(
                headword: word,
                pronunciations: pronunciations,
                lexicalEntries: lexEntries,
                phraseGroups: [],
                notes: []
            )],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
            source: nil
        )
    }
}
