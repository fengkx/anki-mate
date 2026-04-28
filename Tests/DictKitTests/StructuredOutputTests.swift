import XCTest
@testable import DictKit

final class StructuredOutputTests: XCTestCase {
    func testParseTextLookupResultBuildsStructuredSensesAndExamples() throws {
        let raw = try loadTextFixture("apple")

        let result = try DictionaryTextParser.parse(query: "apple", raw: raw, includeSource: false)

        XCTAssertEqual(result.query, "apple")
        XCTAssertEqual(result.metadata.usedSource, .publicAPI)
        XCTAssertEqual(result.metadata.warnings, [])
        XCTAssertNil(result.source)

        let headword = try XCTUnwrap(result.entries.only)
        XCTAssertEqual(headword.headword, "apple")
        XCTAssertEqual(
            headword.pronunciations,
            [
                Pronunciation(dialect: "BrE", ipa: "ˈapl", respelling: nil),
                Pronunciation(dialect: "AmE", ipa: "ˈæp(ə)l", respelling: nil)
            ]
        )

        let lexicalEntry = try XCTUnwrap(headword.lexicalEntries.only)
        XCTAssertEqual(lexicalEntry.partOfSpeech, .noun)
        XCTAssertEqual(lexicalEntry.partOfSpeechLabel, "noun")
        XCTAssertEqual(lexicalEntry.displayIndex, 0)
        XCTAssertEqual(lexicalEntry.pronunciations, headword.pronunciations)
        XCTAssertEqual(lexicalEntry.senses.count, 2)
        XCTAssertEqual(lexicalEntry.senses[0].semanticHint, "(fruit)")
        XCTAssertEqual(lexicalEntry.senses[0].definition, "苹果 píngguǒ")
        XCTAssertEqual(lexicalEntry.senses[0].examples, [])
        XCTAssertEqual(lexicalEntry.senses[1].semanticHint, "(tree)")
        XCTAssertEqual(
            lexicalEntry.senses[1].examples,
            [
                "the apple of sb's eye figurative 掌上明珠",
                "there's a bad apple in every bunch 哪儿都有害群之马",
                "to upset the apple cart 打乱计划",
                "an apple a day keeps the doctor away proverb 天天吃苹果，医生远离我"
            ]
        )
    }

    func testParseTextLookupResultCapturesCountabilityAndPhraseGroupDegradation() throws {
        let raw = try loadTextFixture("light")

        let result = try DictionaryTextParser.parse(query: "light", raw: raw, includeSource: true)

        XCTAssertEqual(result.metadata.usedSource, .publicAPI)
        XCTAssertTrue(result.metadata.warnings.contains("phrase_group_unstructured"))
        let source = try XCTUnwrap(result.source)
        XCTAssertEqual(source.rawText, raw)
        XCTAssertNil(source.rawHTML)

        let headword = try XCTUnwrap(result.entries.only)
        XCTAssertEqual(headword.lexicalEntries.count, 4)
        let nounEntry = try XCTUnwrap(headword.lexicalEntries.first)
        XCTAssertEqual(nounEntry.partOfSpeech, .noun)
        XCTAssertEqual(nounEntry.senses.first?.countability, .uncountable)
        XCTAssertEqual(nounEntry.senses.dropFirst().first?.countability, .countable)

        let phrasalVerbs = try XCTUnwrap(headword.phraseGroups.first { $0.title == "PHRASAL VERB" })
        XCTAssertEqual(phrasalVerbs.items, [])
        XCTAssertNotNil(phrasalVerbs.rawContent)
        XCTAssertTrue(phrasalVerbs.rawContent?.contains("light up") == true)
    }

    func testParseTextLookupResultHandlesUncountableAndCountableSensePrefix() throws {
        let raw = "therapy | BrE ˈθɛrəpi, AmE ˈθɛrəpi | noun uncountable and countable ① (medical treatment) 治疗 zhìliáo▸ music therapy 音乐疗法▸ a course of antibiotic therapy 抗生素疗程 ② (psychotherapy) 心理治疗 xīnlǐ zhìliáo "

        let result = try DictionaryTextParser.parse(query: "therapy", raw: raw, includeSource: true)

        let headword = try XCTUnwrap(result.entries.only)
        let lexicalEntry = try XCTUnwrap(headword.lexicalEntries.only)
        XCTAssertEqual(lexicalEntry.senses.count, 2)
        XCTAssertEqual(lexicalEntry.senses[0].countability, .countableAndUncountable)
        XCTAssertEqual(lexicalEntry.senses[0].semanticHint, "(medical treatment)")
        XCTAssertEqual(lexicalEntry.senses[0].definition, "治疗 zhìliáo")
        XCTAssertEqual(
            lexicalEntry.senses[0].examples,
            [
                "music therapy 音乐疗法",
                "a course of antibiotic therapy 抗生素疗程",
            ]
        )
        XCTAssertEqual(lexicalEntry.senses[1].semanticHint, "(psychotherapy)")
        XCTAssertEqual(lexicalEntry.senses[1].definition, "心理治疗 xīnlǐ zhìliáo")
    }

    func testParseTextLookupResultAssignsPerLexicalEntryPronunciations() throws {
        let raw = try loadTextFixture("elaborate")

        let result = try DictionaryTextParser.parse(query: "elaborate", raw: raw, includeSource: false)

        let headword = try XCTUnwrap(result.entries.only)
        XCTAssertEqual(headword.headword, "elaborate")
        XCTAssertEqual(headword.lexicalEntries.count, 3)
        XCTAssertEqual(headword.lexicalEntries[0].partOfSpeech, .adjective)
        XCTAssertEqual(headword.lexicalEntries[1].partOfSpeech, .verb)
        XCTAssertEqual(headword.lexicalEntries[2].partOfSpeech, .verb)
        XCTAssertEqual(
            headword.lexicalEntries[0].pronunciations,
            [
                Pronunciation(dialect: "BrE", ipa: "ɪˈlab(ə)rət", respelling: nil),
                Pronunciation(dialect: "AmE", ipa: "əˈlæb(ə)rət", respelling: nil)
            ]
        )
        XCTAssertEqual(
            headword.lexicalEntries[1].pronunciations,
            [
                Pronunciation(dialect: "BrE", ipa: "ɪˈlabəreɪt", respelling: nil),
                Pronunciation(dialect: "AmE", ipa: "əˈlæbəˌreɪt", respelling: nil)
            ]
        )
    }

    func testParseTextLookupResultSeparatesPhraseItemsAndReferences() throws {
        let raw = try loadTextFixture("what")

        let result = try DictionaryTextParser.parse(query: "what", raw: raw, includeSource: false)

        let headword = try XCTUnwrap(result.entries.only)
        XCTAssertEqual(headword.lexicalEntries.count, 3)
        XCTAssertEqual(headword.phraseGroups.count, 1)
        XCTAssertEqual(headword.lexicalEntries.map(\.partOfSpeech), [.pronoun, .determiner, .adverb])
        let group = try XCTUnwrap(headword.phraseGroups.only)
        XCTAssertEqual(group.title, "PHRASES")
        XCTAssertNil(group.rawContent)
        XCTAssertEqual(group.items.map(\.phrase), ["what about", "what if"])
        XCTAssertEqual(group.items[0].definition, "…怎么样 … zěnmeyàng")
    }

    func testParseHTMLLookupResultExtractsPhraseDefinitionsGrammarAndNotes() throws {
        let html = try loadHTMLFixture("run")

        let result = try DictionaryHTMLParser.parse(query: "run", html: html, includeSource: true)

        XCTAssertEqual(result.metadata.usedSource, .privateHTML)
        XCTAssertEqual(result.metadata.warnings, [])
        let source = try XCTUnwrap(result.source)
        XCTAssertEqual(source.rawHTML, html)
        XCTAssertNil(source.rawText)

        let headword = try XCTUnwrap(result.entries.only)
        XCTAssertEqual(headword.headword, "run")
        XCTAssertGreaterThanOrEqual(headword.lexicalEntries.count, 2)

        let verbEntry = try XCTUnwrap(headword.lexicalEntries.first { $0.partOfSpeech == .verb })
        XCTAssertTrue(verbEntry.grammar.contains("no object"))
        XCTAssertTrue(verbEntry.inflections.contains("runs"))
        XCTAssertTrue(verbEntry.inflections.contains("running"))
        XCTAssertTrue(verbEntry.inflections.contains("ran"))
        XCTAssertEqual(verbEntry.pronunciations, [Pronunciation(dialect: "AmE", ipa: "rən", respelling: "rən")])
        XCTAssertFalse(verbEntry.senses.isEmpty)
        XCTAssertFalse(verbEntry.senses[0].examples.isEmpty)

        let phrases = try XCTUnwrap(headword.phraseGroups.first { $0.title == "PHRASES" })
        XCTAssertFalse(phrases.items.isEmpty)
        XCTAssertTrue(phrases.items.contains { $0.definition != nil && !$0.phrase.isEmpty })

        XCTAssertTrue(headword.notes.contains { $0.kind == .usage && $0.content.contains("run and") })
        XCTAssertTrue(headword.notes.contains { $0.kind == .etymology && $0.content.contains("Old English") })
    }

    func testParseTextLookupResultIncludesSourcePayloadWhenRequested() throws {
        let raw = try loadTextFixture("apple")

        let result = try DictionaryTextParser.parse(query: "apple", raw: raw, includeSource: true)

        XCTAssertEqual(result.source?.rawText, raw)
        XCTAssertNil(result.source?.rawHTML)
    }

    private func loadTextFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            XCTFail("Missing fixture: \(name)")
            throw NSError(domain: "StructuredOutputTests", code: 1)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func loadHTMLFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html") else {
            XCTFail("Missing HTML fixture: \(name).html")
            throw NSError(domain: "StructuredOutputTests", code: 2)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
