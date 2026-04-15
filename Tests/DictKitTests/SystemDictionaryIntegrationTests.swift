import XCTest

#if canImport(DictKitSystemDictionary)
import DictKit
@testable import DictKitSystemDictionary

final class SystemDictionaryIntegrationTests: XCTestCase {
    func testAutomaticLookupReturnsStructuredEntries() throws {
        let client = SystemDictionaryClient()
        let result = try client.lookup("apple", source: .automatic, includeSource: false)

        XCTAssertEqual(result.query, "apple")
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertFalse(result.entries[0].lexicalEntries.isEmpty || result.entries[0].phraseGroups.isEmpty && result.entries[0].notes.isEmpty)
    }

    func testSpeechClientSynthesizesAudioFromDictionaryLookup() async throws {
        guard ProcessInfo.processInfo.environment["DICTKIT_RUN_SPEECH_TESTS"] == "1" else {
            throw XCTSkip("Set DICTKIT_RUN_SPEECH_TESTS=1 to run AVSpeech integration tests.")
        }

        let client = DictionarySpeechClient()

        do {
            let result = try await client.synthesize(
                LookupSpeechRequest(term: "apple", source: .automatic, selection: .preferredDialectFirst)
            )

            XCTAssertFalse(result.audioData.isEmpty)
            XCTAssertFalse(result.didFallbackToText)
            XCTAssertEqual(result.contentType, "audio/wav")
        } catch SpeechError.synthesisUnavailable {
            throw XCTSkip("AVSpeech synthesis is unavailable in the current test environment.")
        }
    }

    func testSpeechClientSynthesizesAudioFromExistingPronunciation() async throws {
        guard ProcessInfo.processInfo.environment["DICTKIT_RUN_SPEECH_TESTS"] == "1" else {
            throw XCTSkip("Set DICTKIT_RUN_SPEECH_TESTS=1 to run AVSpeech integration tests.")
        }

        let client = DictionarySpeechClient()

        do {
            let result = try await client.synthesize(
                SpeechRequest(
                    text: "elaborate",
                    pronunciation: Pronunciation(dialect: "AmE", ipa: "əˈlæbəˌreɪt", respelling: nil),
                    sourceLabel: "manual"
                )
            )

            XCTAssertFalse(result.audioData.isEmpty)
            XCTAssertEqual(result.pronunciationUsed?.dialect, "AmE")
        } catch SpeechError.synthesisUnavailable {
            throw XCTSkip("AVSpeech synthesis is unavailable in the current test environment.")
        }
    }
}
#else
final class SystemDictionaryIntegrationTests: XCTestCase {
    func testSystemDictionaryModuleIsOptional() {
        XCTAssertTrue(true)
    }
}
#endif
