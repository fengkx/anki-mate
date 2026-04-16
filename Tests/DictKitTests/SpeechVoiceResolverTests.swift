import XCTest
@testable import DictKit
@testable import DictKitSystemDictionary

final class SpeechVoiceResolverTests: XCTestCase {
    func testResolvePrefersMatchingDialectVoiceBeforeGlobalPreference() throws {
        let voices = [
            SpeechVoiceDescriptor(identifier: "en-US-default", language: "en-US", name: "US", quality: 1),
            SpeechVoiceDescriptor(identifier: "en-GB-default", language: "en-GB", name: "UK", quality: 1)
        ]
        let configuration = SpeechSynthesisConfiguration(preferredDialectOrder: ["AmE", "BrE"])
        let pronunciation = Pronunciation(dialect: "BrE", ipa: "wɒt", respelling: nil)

        let resolved = try XCTUnwrap(
            SpeechVoiceResolver.resolveVoice(
                for: pronunciation,
                configuration: configuration,
                availableVoices: voices
            )
        )

        XCTAssertEqual(resolved.identifier, "en-GB-default")
    }

    func testResolveUsesPreferredDialectOrderWhenPronunciationHasNoDialect() throws {
        let voices = [
            SpeechVoiceDescriptor(identifier: "en-GB-default", language: "en-GB", name: "UK", quality: 1),
            SpeechVoiceDescriptor(identifier: "en-US-default", language: "en-US", name: "US", quality: 1)
        ]
        let configuration = SpeechSynthesisConfiguration(preferredDialectOrder: ["AmE", "BrE"])

        let resolved = try XCTUnwrap(
            SpeechVoiceResolver.resolveVoice(
                for: Pronunciation(dialect: nil, ipa: "ˈæp(ə)l", respelling: nil),
                configuration: configuration,
                availableVoices: voices
            )
        )

        XCTAssertEqual(resolved.identifier, "en-US-default")
    }

    func testResolveUsesExplicitVoiceIdentifierWhenAvailable() throws {
        let voices = [
            SpeechVoiceDescriptor(identifier: "voice.custom", language: "en-US", name: "Custom", quality: 1),
            SpeechVoiceDescriptor(identifier: "voice.default", language: "en-US", name: "Default", quality: 1)
        ]
        var configuration = SpeechSynthesisConfiguration()
        configuration.voiceIdentifier = "voice.custom"

        let resolved = try XCTUnwrap(
            SpeechVoiceResolver.resolveVoice(
                for: Pronunciation(dialect: "AmE", ipa: "rən", respelling: nil),
                configuration: configuration,
                availableVoices: voices
            )
        )

        XCTAssertEqual(resolved.identifier, "voice.custom")
    }

    func testResolvePrefersHigherQualityVoicesOverEloquence() throws {
        let voices = [
            SpeechVoiceDescriptor(identifier: "com.apple.eloquence.en-US.Flo", language: "en-US", name: "Flo", quality: 1),
            SpeechVoiceDescriptor(identifier: "com.apple.voice.compact.en-US.Samantha", language: "en-US", name: "Samantha", quality: 1),
            SpeechVoiceDescriptor(identifier: "com.apple.ttsbundle.siri_Aaron_en-US_compact", language: "en-US", name: "Aaron", quality: 1),
            SpeechVoiceDescriptor(identifier: "com.apple.speech.synthesis.voice.Bells", language: "en-US", name: "Bells", quality: 1)
        ]
        let configuration = SpeechSynthesisConfiguration()

        let resolved = try XCTUnwrap(
            SpeechVoiceResolver.resolveVoice(
                for: nil,
                configuration: configuration,
                availableVoices: voices
            )
        )

        // Should pick Siri voice (rank 1) over compact (rank 2), Eloquence (rank 3), and novelty (rank 4)
        XCTAssertEqual(resolved.identifier, "com.apple.ttsbundle.siri_Aaron_en-US_compact")
    }

    func testResolvePrefersCompactOverEloquence() throws {
        let voices = [
            SpeechVoiceDescriptor(identifier: "com.apple.eloquence.en-US.Flo", language: "en-US", name: "Flo", quality: 1),
            SpeechVoiceDescriptor(identifier: "com.apple.voice.compact.en-US.Samantha", language: "en-US", name: "Samantha", quality: 1)
        ]
        let configuration = SpeechSynthesisConfiguration()

        let resolved = try XCTUnwrap(
            SpeechVoiceResolver.resolveVoice(
                for: nil,
                configuration: configuration,
                availableVoices: voices
            )
        )

        XCTAssertEqual(resolved.identifier, "com.apple.voice.compact.en-US.Samantha")
    }
}
