import Foundation

func normalizeWhitespace(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func parsePronunciations(_ text: String) -> [Pronunciation] {
    let normalized = normalizeWhitespace(text)
    guard !normalized.isEmpty else {
        return []
    }

    let pattern = #"(?:(BrE)\s+([^|]+?))(?=,\s*AmE\b|$)|(?:(AmE)\s+([^|]+))"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return [normalizedPronunciation(from: normalized, dialect: nil)]
    }

    let nsRange = NSRange(normalized.startIndex..., in: normalized)
    let matches = regex.matches(in: normalized, range: nsRange)

    if matches.isEmpty {
        return [normalizedPronunciation(from: normalized, dialect: nil)]
    }

    return matches.compactMap { match in
        if let dialectRange = Range(match.range(at: 1), in: normalized),
           let valueRange = Range(match.range(at: 2), in: normalized) {
            return normalizedPronunciation(from: String(normalized[valueRange]), dialect: String(normalized[dialectRange]))
        }

        if let dialectRange = Range(match.range(at: 3), in: normalized),
           let valueRange = Range(match.range(at: 4), in: normalized) {
            return normalizedPronunciation(from: String(normalized[valueRange]), dialect: String(normalized[dialectRange]))
        }

        return nil
    }
}

func normalizePronunciationToken(_ value: String) -> String {
    value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func deduplicatedPronunciations(_ pronunciations: [Pronunciation]) -> [Pronunciation] {
    var result: [Pronunciation] = []
    for pronunciation in pronunciations where !result.contains(pronunciation) {
        result.append(pronunciation)
    }
    return result
}

func mapPartOfSpeech(from label: String) -> PartOfSpeech {
    let lower = label.lowercased()
    if lower.contains("adverb") { return .adverb }
    if lower.contains("pronoun") { return .pronoun }
    if lower.contains("noun") { return .noun }
    if lower.contains("verb") || lower == "combining form" { return .verb }
    if lower.contains("adjective") { return .adjective }
    if lower.contains("determiner") { return .determiner }
    if lower.contains("preposition") { return .preposition }
    if lower.contains("conjunction") { return .conjunction }
    if lower.contains("article") { return .article }
    if lower.contains("abbreviation") { return .abbreviation }
    if lower.contains("interjection") || lower.contains("exclamation") { return .interjection }
    return .other
}

private func normalizedPronunciation(from rawValue: String, dialect: String?) -> Pronunciation {
    let token = normalizePronunciationToken(rawValue)
    return Pronunciation(dialect: dialect, ipa: token, respelling: nil)
}

extension Array where Element == String {
    func uniqued() -> [String] {
        var result: [String] = []
        for item in self where !result.contains(item) {
            result.append(item)
        }
        return result
    }
}
