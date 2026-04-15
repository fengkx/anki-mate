import XCTest
@testable import DictKit
@testable import DictKitSystemDictionary

final class SpeechVoiceResolverTests: XCTestCase {
    func testResolvePrefersMatchingDialectVoiceBeforeGlobalPreference() throws {
        let voices = [
            SpeechVoiceDescriptor(identifier: "en-US-default", language: "en-US", name: "US"),
            SpeechVoiceDescriptor(identifier: "en-GB-default", language: "en-GB", name: "UK")
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
            SpeechVoiceDescriptor(identifier: "en-GB-default", language: "en-GB", name: "UK"),
            SpeechVoiceDescriptor(identifier: "en-US-default", language: "en-US", name: "US")
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
            SpeechVoiceDescriptor(identifier: "voice.custom", language: "en-US", name: "Custom"),
            SpeechVoiceDescriptor(identifier: "voice.default", language: "en-US", name: "Default")
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
}
