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
            if let exact = availableVoices.first(where: { $0.language.caseInsensitiveCompare(language) == .orderedSame }) {
                return exact
            }

            if let prefix = availableVoices.first(where: { $0.language.lowercased().hasPrefix(language.lowercased()) }) {
                return prefix
            }
        }

        return availableVoices.first
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
            SpeechVoiceDescriptor(identifier: $0.identifier, language: $0.language, name: $0.name)
        }
    }
    #endif
}
