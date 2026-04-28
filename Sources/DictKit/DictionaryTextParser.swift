import Foundation

public enum DictionaryTextParser {
    public static func parse(query: String, raw: String, includeSource: Bool) throws -> LookupResult {
        let normalized = normalizeWhitespace(raw)
        guard !normalized.isEmpty else {
            throw LookupError.parseFailed
        }

        if let labeledSections = parseTopLevelPronunciationSections(query: query, raw: normalized) {
            let lexicalEntries = labeledSections.enumerated().map { index, section in
                buildLexicalEntry(
                    displayIndex: index,
                    label: section.partOfSpeechLabel,
                    pronunciations: parsePronunciations(section.pronunciationText),
                    body: section.body
                )
            }

            let headwordPronunciations = deduplicatedPronunciations(lexicalEntries.flatMap(\.pronunciations))
            return LookupResult(
                query: query,
                entries: [
                    HeadwordEntry(
                        headword: query,
                        pronunciations: headwordPronunciations,
                        lexicalEntries: lexicalEntries,
                        phraseGroups: [],
                        notes: []
                    )
                ],
                metadata: LookupMetadata(usedSource: .publicAPI, warnings: []),
                source: includeSource ? SourcePayload(rawText: raw, rawHTML: nil) : nil
            )
        }

        let top = splitTopLevelPipes(normalized, maxSplits: 2)
        let hasStructuredTopLevel = top.count >= 3
        let headword = hasStructuredTopLevel ? normalizeHeadword(query: query, rawHeadword: top[0]) : query
        let pronunciationText = hasStructuredTopLevel ? top[1] : ""
        let body = hasStructuredTopLevel ? normalizeBodyForParsing(top[2]) : normalized
        let headwordPronunciations = parsePronunciations(pronunciationText)

        let (mainBody, specialSections) = splitSpecialSections(body)
        let sections = mainBody.isEmpty ? [] : splitLetterSections(mainBody)
        let classifiedSections = sections.map { classifySection(label: $0.label, content: $0.content) }

        var lexicalEntries: [LexicalEntry] = []
        var phraseItems: [PhraseItem] = []
        var phraseGroups: [PhraseGroup] = []
        var notes: [Note] = []
        var warnings: [String] = []

        for section in classifiedSections {
            switch section.kind {
            case let .lexical(label):
                lexicalEntries.append(
                    buildLexicalEntry(
                        displayIndex: lexicalEntries.count,
                        label: label,
                        pronunciations: headwordPronunciations,
                        body: stripLeadingLabel(label, from: section.content)
                    )
                )
            case let .phrase(name):
                phraseItems.append(parsePhraseItem(name: name, content: section.content))
            case .reference:
                notes.append(Note(kind: .reference, content: section.content))
            case .unknown:
                warnings.append("sense_parse_degraded")
                lexicalEntries.append(
                    LexicalEntry(
                        partOfSpeech: .other,
                        partOfSpeechLabel: "unknown",
                        displayIndex: lexicalEntries.count,
                        pronunciations: headwordPronunciations,
                        senses: [
                            Sense(
                                number: 1,
                                semanticHint: nil,
                                definition: section.content,
                                examples: [],
                                registers: [],
                                countability: nil
                            )
                        ],
                        grammar: [],
                        inflections: []
                    )
                )
            }
        }

        if !phraseItems.isEmpty {
            phraseGroups.append(PhraseGroup(title: "PHRASES", items: phraseItems, rawContent: nil))
        }

        for specialSection in specialSections {
            switch specialSection.title {
            case "ORIGIN":
                notes.append(Note(kind: .etymology, content: specialSection.content))
            case "PHRASES", "PHRASAL VERBS", "PHRASAL VERB", "DERIVATIVES":
                warnings.append("phrase_group_unstructured")
                phraseGroups.append(PhraseGroup(title: specialSection.title, items: [], rawContent: specialSection.content))
            default:
                notes.append(Note(kind: .usage, content: specialSection.content))
            }
        }

        if lexicalEntries.isEmpty && phraseGroups.isEmpty && notes.isEmpty {
            warnings.append("sense_parse_degraded")
            lexicalEntries = [
                LexicalEntry(
                    partOfSpeech: .other,
                    partOfSpeechLabel: "unknown",
                    displayIndex: 0,
                    pronunciations: headwordPronunciations,
                    senses: [
                        Sense(number: 1, semanticHint: nil, definition: body, examples: [], registers: [], countability: nil)
                    ],
                    grammar: [],
                    inflections: []
                )
            ]
        }

        return LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: headword,
                    pronunciations: headwordPronunciations,
                    lexicalEntries: lexicalEntries,
                    phraseGroups: phraseGroups,
                    notes: notes
                )
            ],
            metadata: LookupMetadata(usedSource: .publicAPI, warnings: warnings.uniqued()),
            source: includeSource ? SourcePayload(rawText: raw, rawHTML: nil) : nil
        )
    }

    private static func splitTopLevelPipes(_ text: String, maxSplits: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        var splits = 0

        for character in text {
            if character == "|" && splits < maxSplits {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                splits += 1
            } else {
                current.append(character)
            }
        }

        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func splitLetterSections(_ body: String) -> [(label: String, content: String)] {
        let normalized = normalizeWhitespace(body)
        let pattern = #"\b([A-Z])\.\s+"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [("", normalized)]
        }

        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        let matches = regex.matches(in: normalized, range: nsRange)
        guard !matches.isEmpty else {
            return [("", normalized)]
        }

        var sections: [(String, String)] = []

        for (index, match) in matches.enumerated() {
            guard let labelRange = Range(match.range(at: 1), in: normalized),
                  let fullRange = Range(match.range(at: 0), in: normalized) else {
                continue
            }

            let contentStart = fullRange.upperBound
            let contentEnd: String.Index

            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range(at: 0), in: normalized) {
                contentEnd = nextRange.lowerBound
            } else {
                contentEnd = normalized.endIndex
            }

            sections.append((
                String(normalized[labelRange]),
                String(normalized[contentStart..<contentEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return sections
    }

    private static func normalizeBodyForParsing(_ body: String) -> String {
        let normalized = normalizeWhitespace(body)
        let pattern = #"^,\s*[^|]+\|\s*[^|]+\|\s*(.+)$"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(normalized.startIndex..., in: normalized)
            if let match = regex.firstMatch(in: normalized, range: nsRange),
               let bodyRange = Range(match.range(at: 1), in: normalized) {
                return String(normalized[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return normalized
    }

    private static func normalizeHeadword(query: String, rawHeadword: String) -> String {
        let normalized = normalizeWhitespace(rawHeadword)
        guard !normalized.isEmpty else {
            return query
        }

        let escapedQuery = NSRegularExpression.escapedPattern(for: query)
        let pattern = "^\(escapedQuery)(?:\\s*\\d+(?:\\s*,.*)?)?$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
           regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil {
            return query
        }

        return normalized
    }

    private static func splitSpecialSections(_ body: String) -> (main: String, special: [SpecialSection]) {
        let normalized = normalizeBodyForParsing(body)
        guard !normalized.isEmpty else {
            return ("", [])
        }

        let markers = ["PHRASAL VERBS", "PHRASAL VERB", "PHRASES", "DERIVATIVES", "ORIGIN"]
        let escapedMarkers = markers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"\b("# + escapedMarkers + #")\b"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (normalized, [])
        }

        let nsRange = NSRange(normalized.startIndex..., in: normalized)
        let matches = regex.matches(in: normalized, range: nsRange)
        guard let firstMatch = matches.first,
              let firstRange = Range(firstMatch.range(at: 0), in: normalized) else {
            return (normalized, [])
        }

        let main = String(normalized[..<firstRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let special = matches.compactMap { match -> SpecialSection? in
            guard let markerRange = Range(match.range(at: 1), in: normalized),
                  let fullRange = Range(match.range(at: 0), in: normalized) else {
                return nil
            }

            let start = fullRange.upperBound
            let end: String.Index
            if let index = matches.firstIndex(where: { $0.range.location > match.range.location }),
               let nextRange = Range(matches[index].range(at: 0), in: normalized) {
                end = nextRange.lowerBound
            } else {
                end = normalized.endIndex
            }

            return SpecialSection(
                title: String(normalized[markerRange]),
                content: String(normalized[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return (main, special)
    }

    private static func classifySection(label: String, content: String) -> ClassifiedSection {
        let normalized = normalizeWhitespace(content)
        guard !normalized.isEmpty else {
            return ClassifiedSection(label: label, content: normalized, kind: .unknown)
        }

        let lower = normalized.lowercased()

        if normalized.hasPrefix("→") || normalized.hasPrefix("▸") || lower.hasPrefix("see also ") {
            return ClassifiedSection(label: label, content: normalized, kind: .reference)
        }

        let phrasePattern = #"^([A-Za-z][A-Za-z'.-]*(?:\s+[A-Za-z][A-Za-z'.-]*){0,4})\s+phrase\b"#
        if let regex = try? NSRegularExpression(pattern: phrasePattern, options: [.caseInsensitive]),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let nameRange = Range(match.range(at: 1), in: normalized) {
            return ClassifiedSection(label: label, content: normalized, kind: .phrase(String(normalized[nameRange]).lowercased()))
        }

        for name in compoundPartOfSpeechNames + basicPartOfSpeechNames {
            if lower == name || lower.hasPrefix(name + " ") {
                return ClassifiedSection(label: label, content: normalized, kind: .lexical(name))
            }
        }

        let pluralNounPattern = #"^\w[\w'-]*\s+plural\s+noun\b"#
        if let regex = try? NSRegularExpression(pattern: pluralNounPattern, options: [.caseInsensitive]),
           regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil {
            return ClassifiedSection(label: label, content: normalized, kind: .lexical("plural noun"))
        }

        let allPOSWords = compoundPartOfSpeechNames + basicPartOfSpeechNames
        let firstWord = lower.components(separatedBy: .whitespaces).first ?? ""
        let firstWordIsInPOSName = allPOSWords.contains(where: { $0.contains(firstWord) })
        if !firstWord.isEmpty && !firstWordIsInPOSName {
            let escapedPOSList = allPOSWords
                .sorted { $0.count > $1.count }
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            let pattern = #"^\w[\w'-]*\s+("# + escapedPOSList + #")\b"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
               let posRange = Range(match.range(at: 1), in: normalized) {
                return ClassifiedSection(label: label, content: normalized, kind: .lexical(String(normalized[posRange]).lowercased()))
            }
        }

        let combiningPattern = #"^-?\w[\w'-]*-?\s+combining\s+form\b"#
        if let regex = try? NSRegularExpression(pattern: combiningPattern, options: [.caseInsensitive]),
           regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil {
            return ClassifiedSection(label: label, content: normalized, kind: .lexical("combining form"))
        }

        let irregularVerbPattern = #"^past\s+(?:tense|participle)\b"#
        if let regex = try? NSRegularExpression(pattern: irregularVerbPattern, options: [.caseInsensitive]),
           regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) != nil {
            let detectedName = (compoundPartOfSpeechNames + basicPartOfSpeechNames).first(where: { lower.contains($0) }) ?? "verb"
            return ClassifiedSection(label: label, content: normalized, kind: .lexical(detectedName))
        }

        let fullName = extractPOSName(from: lower)
        if (compoundPartOfSpeechNames + basicPartOfSpeechNames).contains(where: { fullName.contains($0) }) {
            return ClassifiedSection(label: label, content: normalized, kind: .lexical(fullName))
        }

        return ClassifiedSection(label: label, content: normalized, kind: .unknown)
    }

    private static func extractPOSName(from lower: String) -> String {
        let stopPattern = #"[①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]|\s+\(|\s+\d+\b|$"#
        if let regex = try? NSRegularExpression(pattern: stopPattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range, in: lower) {
            return String(lower[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return lower.trimmingCharacters(in: .whitespaces)
    }

    private static func stripLeadingLabel(_ label: String, from content: String) -> String {
        let normalized = normalizeWhitespace(content)
        guard normalized.lowercased().hasPrefix(label.lowercased()) else {
            return normalized
        }

        let start = normalized.index(normalized.startIndex, offsetBy: label.count)
        return String(normalized[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildLexicalEntry(
        displayIndex: Int,
        label: String,
        pronunciations: [Pronunciation],
        body: String
    ) -> LexicalEntry {
        LexicalEntry(
            partOfSpeech: mapPartOfSpeech(from: label),
            partOfSpeechLabel: label,
            displayIndex: displayIndex,
            pronunciations: pronunciations,
            senses: parsePublicSenses(from: body),
            grammar: [],
            inflections: []
        )
    }

    private static func splitSenseSegments(_ text: String) -> [(number: Int, text: String)] {
        let normalized = normalizeWhitespace(text)
        var segments: [(Int, String)] = []
        var currentNumber = 1
        var current = ""

        for character in normalized {
            if let number = circledNumberMap[character] {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append((currentNumber, current.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentNumber = number
                current = ""
            } else {
                current.append(character)
            }
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append((currentNumber, current.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        if segments.isEmpty {
            segments = [(1, normalized)]
        }

        if segments.count > 1,
           isStandaloneCountabilityPrefix(segments[0].1),
           segments[0].0 == segments[1].0 {
            segments[1] = (
                segments[1].0,
                normalizeWhitespace("\(segments[0].1) \(segments[1].1)")
            )
            segments.removeFirst()
        }

        if segments.count == 1,
           segments[0].1.hasPrefix("("),
           segments[0].1.contains("; (") {
            return segments[0].1
                .components(separatedBy: "; (")
                .enumerated()
                .map { index, part -> (Int, String) in
                    let text = index == 0 ? part : "(\(part)"
                    return (index + 1, normalizeWhitespace(text))
                }
        }

        return segments
    }

    private static func isStandaloneCountabilityPrefix(_ text: String) -> Bool {
        switch normalizeWhitespace(text).lowercased() {
        case "countable",
             "uncountable",
             "countable and uncountable",
             "uncountable and countable":
            return true
        default:
            return false
        }
    }

    private static func parsePublicSenses(from rawBody: String) -> [Sense] {
        splitSenseSegments(rawBody).map { segment in
            var remaining = normalizeWhitespace(segment.text)

            let countability: Countability?
            if remaining.lowercased().hasPrefix("countable and uncountable ") {
                countability = .countableAndUncountable
                remaining = String(remaining.dropFirst("countable and uncountable ".count))
            } else if remaining.lowercased().hasPrefix("uncountable and countable ") {
                countability = .countableAndUncountable
                remaining = String(remaining.dropFirst("uncountable and countable ".count))
            } else if remaining.lowercased().hasPrefix("uncountable ") {
                countability = .uncountable
                remaining = String(remaining.dropFirst("uncountable ".count))
            } else if remaining.lowercased().hasPrefix("countable ") {
                countability = .countable
                remaining = String(remaining.dropFirst("countable ".count))
            } else {
                countability = nil
            }

            var registers: [String] = []
            var didConsumeRegister = true
            while didConsumeRegister {
                didConsumeRegister = false
                let lower = remaining.lowercased()
                for token in registerTokens {
                    let prefix = token.pattern + " "
                    if lower.hasPrefix(prefix) {
                        registers.append(token.value)
                        remaining = String(remaining.dropFirst(prefix.count))
                        didConsumeRegister = true
                        break
                    }
                }
            }

            let semanticHint: String?
            if remaining.hasPrefix("("), let end = remaining.firstIndex(of: ")") {
                semanticHint = String(remaining[...end])
                remaining = String(remaining[remaining.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                semanticHint = nil
            }

            let chunks = remaining
                .split(separator: "▸", omittingEmptySubsequences: false)
                .map { normalizeWhitespace(String($0)) }
                .filter { !$0.isEmpty }

            let definition = chunks.first ?? remaining
            let examples = Array(chunks.dropFirst())

            return Sense(
                number: segment.number,
                semanticHint: semanticHint,
                definition: definition,
                examples: examples,
                registers: registers,
                countability: countability
            )
        }
    }

    private static func parsePhraseItem(name: String, content: String) -> PhraseItem {
        let normalized = normalizeWhitespace(content)
        let prefix = "\(name) phrase"
        let stripped: String
        if normalized.lowercased().hasPrefix(prefix.lowercased()) {
            stripped = String(normalized.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            stripped = normalized
        }

        let senses = parsePublicSenses(from: stripped)
        return PhraseItem(
            phrase: name,
            definition: senses.first?.definition,
            examples: senses.flatMap(\.examples)
        )
    }

    private static func parseTopLevelPronunciationSections(query: String, raw: String) -> [TopLevelPronunciationSection]? {
        let normalized = normalizeWhitespace(raw)
        let escapedQuery = NSRegularExpression.escapedPattern(for: query)
        let prefixPattern = #"^\#(escapedQuery)\s+"#
        guard let prefixRegex = try? NSRegularExpression(pattern: prefixPattern, options: [.caseInsensitive]),
              let prefixMatch = prefixRegex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let prefixRange = Range(prefixMatch.range, in: normalized) else {
            return nil
        }

        let remainder = String(normalized[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"([A-Z])\.\s+([^|]+?)\s+\|\s+([^|]+?)\s+\|\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let matches = regex.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
        guard !matches.isEmpty else {
            return nil
        }

        return matches.enumerated().compactMap { index, match in
            guard let labelRange = Range(match.range(at: 2), in: remainder),
                  let pronunciationRange = Range(match.range(at: 3), in: remainder),
                  let fullRange = Range(match.range(at: 0), in: remainder) else {
                return nil
            }

            let bodyStart = fullRange.upperBound
            let bodyEnd: String.Index
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range(at: 0), in: remainder) {
                bodyEnd = nextRange.lowerBound
            } else {
                bodyEnd = remainder.endIndex
            }

            return TopLevelPronunciationSection(
                partOfSpeechLabel: normalizeWhitespace(String(remainder[labelRange]).lowercased()),
                pronunciationText: String(remainder[pronunciationRange]),
                body: String(remainder[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private struct SpecialSection {
    let title: String
    let content: String
}

private let compoundPartOfSpeechNames = [
    "transitive verb",
    "intransitive verb",
    "modal verb",
    "auxiliary verb",
    "linking verb",
    "copular verb",
    "reflexive verb",
    "definite article",
    "indefinite article",
    "proper noun",
    "plural noun",
    "combining form"
]

private let basicPartOfSpeechNames = [
    "noun", "pronoun", "verb", "adjective", "adverb",
    "determiner", "exclamation", "preposition",
    "conjunction", "interjection", "article", "abbreviation"
]

private enum ClassifiedKind {
    case lexical(String)
    case phrase(String)
    case reference
    case unknown
}

private struct ClassifiedSection {
    let label: String
    let content: String
    let kind: ClassifiedKind
}

private let circledNumberMap: [Character: Int] = [
    "①": 1, "②": 2, "③": 3, "④": 4, "⑤": 5,
    "⑥": 6, "⑦": 7, "⑧": 8, "⑨": 9, "⑩": 10,
    "⑪": 11, "⑫": 12, "⑬": 13, "⑭": 14, "⑮": 15,
    "⑯": 16, "⑰": 17, "⑱": 18, "⑲": 19, "⑳": 20
]

private let registerTokens: [(pattern: String, value: String)] = [
    ("chiefly north american", "North American"),
    ("north american", "North American"),
    ("us english", "US English"),
    ("british", "British"),
    ("informal", "informal"),
    ("formal", "formal"),
    ("literary", "literary"),
    ("figurative", "figurative"),
    ("proverb", "proverb")
]

private struct TopLevelPronunciationSection {
    let partOfSpeechLabel: String
    let pronunciationText: String
    let body: String
}
