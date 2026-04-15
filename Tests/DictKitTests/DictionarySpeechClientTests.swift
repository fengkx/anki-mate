import Foundation
import XCTest
@testable import DictKit
@testable import DictKitSystemDictionary

final class DictionarySpeechClientTests: XCTestCase {
    func testSynthesizeUsesProvidedPronunciationWithoutLookup() async throws {
        let engine = FakeSpeechSynthesizer()
        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: SpeechSynthesisConfiguration(),
            lookup: { _ in
                XCTFail("Lookup should not be called for direct synthesis requests.")
                throw LookupError.notFound
            },
            synthesizer: engine
        )

        let result = try await client.synthesize(
            SpeechRequest(
                text: "apple",
                pronunciation: Pronunciation(dialect: "AmE", ipa: "ˈæp(ə)l", respelling: nil),
                sourceLabel: "manual"
            )
        )

        XCTAssertEqual(result.textSpoken, "apple")
        XCTAssertEqual(result.pronunciationUsed?.ipa, "ˈæp(ə)l")
        XCTAssertFalse(result.didFallbackToText)
        XCTAssertEqual(engine.synthesizedRequests.count, 1)
    }

    func testLookupSynthesizeSelectsRequestedLexicalEntryDialect() async throws {
        let engine = FakeSpeechSynthesizer()
        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: SpeechSynthesisConfiguration(),
            lookup: { _ in Self.elaborateResult },
            synthesizer: engine
        )

        let result = try await client.synthesize(
            LookupSpeechRequest(
                term: "elaborate",
                source: .automatic,
                selection: .lexicalEntry(index: 1, dialect: "AmE")
            )
        )

        XCTAssertEqual(result.pronunciationUsed?.ipa, "əˈlæbəˌreɪt")
        XCTAssertEqual(result.pronunciationUsed?.dialect, "AmE")
    }

    func testLookupSynthesizeFallsBackToPlainTextWhenPronunciationMissing() async throws {
        let engine = FakeSpeechSynthesizer()
        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: SpeechSynthesisConfiguration(),
            lookup: { _ in Self.missingPronunciationResult },
            synthesizer: engine
        )

        let result = try await client.synthesize(
            LookupSpeechRequest(term: "fallback", source: .automatic, selection: .preferredDialectFirst)
        )

        XCTAssertTrue(result.didFallbackToText)
        XCTAssertEqual(result.pronunciationUsed, nil)
        XCTAssertTrue(result.warnings.contains("missing_pronunciation_fallback"))
        XCTAssertEqual(engine.synthesizedRequests.last?.text, "fallback")
    }

    func testLookupSynthesizeFailsWhenStrictFallbackPolicyConfigured() async throws {
        let engine = FakeSpeechSynthesizer()
        var configuration = SpeechSynthesisConfiguration()
        configuration.fallbackPolicy = .failIfNoPronunciation

        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: configuration,
            lookup: { _ in Self.missingPronunciationResult },
            synthesizer: engine
        )

        await XCTAssertThrowsErrorAsync(
            try await client.synthesize(
                LookupSpeechRequest(term: "fallback", source: .automatic, selection: .preferredDialectFirst)
            )
        ) { error in
            XCTAssertEqual(error as? SpeechError, .noPronunciationCandidates)
        }
    }

    func testResolveSpeechRequestsExpandsAllCandidatesForBatchWorkflows() throws {
        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: SpeechSynthesisConfiguration(),
            lookup: { _ in Self.elaborateResult },
            synthesizer: FakeSpeechSynthesizer()
        )

        let requests = try client.resolveSpeechRequests(
            LookupSpeechRequest(term: "elaborate", source: .automatic, selection: .allCandidates)
        )

        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.first?.pronunciation?.dialect, "AmE")
    }

    func testLookupSynthesizeThrowsWhenExplicitDialectIsUnavailable() async throws {
        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: SpeechSynthesisConfiguration(),
            lookup: { _ in Self.elaborateResult },
            synthesizer: FakeSpeechSynthesizer()
        )

        await XCTAssertThrowsErrorAsync(
            try await client.synthesize(
                LookupSpeechRequest(term: "elaborate", source: .automatic, selection: .exactDialect("AuE"))
            )
        ) { error in
            XCTAssertEqual(error as? SpeechError, .noPronunciationCandidates)
        }
    }

    func testSynthesizeBatchCollectsSuccessesAndFailures() async {
        let engine = FakeSpeechSynthesizer(failingTexts: ["fail"])
        let client = DictionarySpeechClient(
            dictionaryClient: SystemDictionaryClient(),
            configuration: SpeechSynthesisConfiguration(),
            lookup: { _ in Self.elaborateResult },
            synthesizer: engine
        )

        let batch = await client.synthesizeBatch([
            SpeechRequest(text: "apple", pronunciation: Pronunciation(dialect: "AmE", ipa: "ˈæp(ə)l", respelling: nil), sourceLabel: "ok"),
            SpeechRequest(text: "fail", pronunciation: Pronunciation(dialect: "AmE", ipa: "feɪl", respelling: nil), sourceLabel: "bad")
        ])

        XCTAssertEqual(batch.successes.count, 1)
        XCTAssertEqual(batch.failures.count, 1)
        XCTAssertEqual(batch.failures.first?.text, "fail")
        XCTAssertEqual(batch.failures.first?.error, .synthesisUnavailable)
    }

    private static let elaborateResult = LookupResult(
        query: "elaborate",
        entries: [
            HeadwordEntry(
                headword: "elaborate",
                pronunciations: [
                    Pronunciation(dialect: "BrE", ipa: "ɪˈlab(ə)rət", respelling: nil),
                    Pronunciation(dialect: "AmE", ipa: "əˈlæb(ə)rət", respelling: nil),
                    Pronunciation(dialect: "BrE", ipa: "ɪˈlabəreɪt", respelling: nil),
                    Pronunciation(dialect: "AmE", ipa: "əˈlæbəˌreɪt", respelling: nil)
                ],
                lexicalEntries: [
                    LexicalEntry(
                        partOfSpeech: .adjective,
                        partOfSpeechLabel: "adjective",
                        displayIndex: 0,
                        pronunciations: [
                            Pronunciation(dialect: "BrE", ipa: "ɪˈlab(ə)rət", respelling: nil),
                            Pronunciation(dialect: "AmE", ipa: "əˈlæb(ə)rət", respelling: nil)
                        ],
                        senses: [],
                        grammar: [],
                        inflections: []
                    ),
                    LexicalEntry(
                        partOfSpeech: .verb,
                        partOfSpeechLabel: "transitive verb",
                        displayIndex: 1,
                        pronunciations: [
                            Pronunciation(dialect: "BrE", ipa: "ɪˈlabəreɪt", respelling: nil),
                            Pronunciation(dialect: "AmE", ipa: "əˈlæbəˌreɪt", respelling: nil)
                        ],
                        senses: [],
                        grammar: [],
                        inflections: []
                    )
                ],
                phraseGroups: [],
                notes: []
            )
        ],
        metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
        source: nil
    )

    private static let missingPronunciationResult = LookupResult(
        query: "fallback",
        entries: [
            HeadwordEntry(
                headword: "fallback",
                pronunciations: [],
                lexicalEntries: [
                    LexicalEntry(
                        partOfSpeech: .noun,
                        partOfSpeechLabel: "noun",
                        displayIndex: 0,
                        pronunciations: [],
                        senses: [],
                        grammar: [],
                        inflections: []
                    )
                ],
                phraseGroups: [],
                notes: []
            )
        ],
        metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
        source: nil
    )
}

private final class FakeSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private(set) var synthesizedRequests: [ResolvedSpeechRequest] = []
    private let failingTexts: Set<String>

    init(failingTexts: Set<String> = []) {
        self.failingTexts = failingTexts
    }

    func speak(_ request: ResolvedSpeechRequest) async throws {
        if failingTexts.contains(request.text) {
            throw SpeechError.synthesisUnavailable
        }
        synthesizedRequests.append(request)
    }

    func synthesize(_ request: ResolvedSpeechRequest) async throws -> SynthesizedSpeechPayload {
        if failingTexts.contains(request.text) {
            throw SpeechError.synthesisUnavailable
        }
        synthesizedRequests.append(request)
        return SynthesizedSpeechPayload(
            audioData: Data("wave".utf8),
            voiceIdentifier: "voice.default",
            language: request.languageHint ?? "en-US"
        )
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw.")
    } catch {
        handler(error)
    }
}
