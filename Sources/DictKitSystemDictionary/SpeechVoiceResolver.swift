import DictKit
import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

enum SpeechVoiceResolver {
    static func resolveVoice(
        for pronunciation: Pronunciation?,
        configuration: SpeechSynthesisConfiguration,
        availableVoices: [SpeechVoiceDescriptor]
    ) -> SpeechVoiceDescriptor? {
        if let voiceIdentifier = configuration.voiceIdentifier {
            return availableVoices.first { $0.identifier == voiceIdentifier }
        }

        guard !availableVoices.isEmpty else {
            return nil
        }

        let preferredLanguages = preferredLanguages(for: pronunciation, configuration: configuration)
        for language in preferredLanguages {
            let candidates = availableVoices.filter {
                $0.language.caseInsensitiveCompare(language) == .orderedSame ||
                $0.language.lowercased().hasPrefix(language.lowercased())
            }
            if let best = bestVoice(from: candidates) {
                return best
            }
        }

        return bestVoice(from: availableVoices) ?? availableVoices.first
    }

    /// Prefer higher-quality, natural-sounding voices over Eloquence and novelty voices.
    private static func bestVoice(from voices: [SpeechVoiceDescriptor]) -> SpeechVoiceDescriptor? {
        // Sort by quality tier: higher quality first, then prefer non-Eloquence
        // and non-novelty voices for more natural pronunciation.
        let ranked = voices.sorted { lhs, rhs in
            let lhsRank = voiceRank(lhs)
            let rhsRank = voiceRank(rhs)
            return lhsRank < rhsRank
        }
        return ranked.first
    }

    /// Lower rank = better voice for dictionary pronunciation.
    private static func voiceRank(_ voice: SpeechVoiceDescriptor) -> Int {
        let id = voice.identifier.lowercased()
        // Premium/enhanced voices (quality >= 2)
        if voice.quality >= 2 { return 0 }
        // Siri voices — generally good quality even at compact level
        if id.contains("siri_") { return 1 }
        // Standard compact voices (Samantha, Daniel, Karen, etc.)
        if id.contains("voice.compact.") { return 2 }
        // Eloquence voices — robotic but functional
        if id.contains("eloquence") { return 3 }
        // Novelty/effect voices (Bells, Boing, Whisper, etc.)
        return 4
    }

    static func preferredLanguages(
        for pronunciation: Pronunciation?,
        configuration: SpeechSynthesisConfiguration
    ) -> [String] {
        var result: [String] = []

        if let dialectLanguage = pronunciation?.defaultSpeechLanguageCode {
            result.append(dialectLanguage)
        }

        if let languageHint = configuration.languageHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !languageHint.isEmpty {
            result.append(languageHint)
        }

        for dialect in configuration.preferredDialectOrder {
            if let language = languageCode(forDialect: dialect) {
                result.append(language)
            }
        }

        #if canImport(AVFAudio)
        result.append(AVSpeechSynthesisVoice.currentLanguageCode())
        #endif

        var unique: [String] = []
        for item in result where !item.isEmpty && !unique.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
            unique.append(item)
        }

        return unique
    }

    static func languageCode(forDialect dialect: String?) -> String? {
        switch dialect?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ame", "us", "american english":
            return "en-US"
        case "bre", "uk", "british english":
            return "en-GB"
        default:
            return nil
        }
    }

    #if canImport(AVFAudio)
    static func availableVoices() -> [SpeechVoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map {
            SpeechVoiceDescriptor(identifier: $0.identifier, language: $0.language, name: $0.name, quality: $0.quality.rawValue)
        }
    }
    #endif
}
