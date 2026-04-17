import DictKit
import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

public enum InflectionKind: String, Codable, Equatable, Sendable {
    case plural
    case thirdPersonSingular
    case presentParticiple
    case pastOrPastParticiple
    case comparative
    case superlative
    case unknownDerivedForm

    public var shortDescription: String {
        switch self {
        case .plural:
            return "plural"
        case .thirdPersonSingular:
            return "3rd person singular"
        case .presentParticiple:
            return "present participle"
        case .pastOrPastParticiple:
            return "past tense / past participle"
        case .comparative:
            return "comparative"
        case .superlative:
            return "superlative"
        case .unknownDerivedForm:
            return "derived form"
        }
    }
}

public struct ResolvedLookup: Equatable, Sendable {
    public let word: String
    public let sourceForm: String?
    public let inflectionKind: InflectionKind?
    public let expectedPartOfSpeech: PartOfSpeech?
    public let lookupResult: LookupResult

    public init(
        word: String,
        sourceForm: String?,
        inflectionKind: InflectionKind?,
        expectedPartOfSpeech: PartOfSpeech?,
        lookupResult: LookupResult
    ) {
        self.word = word
        self.sourceForm = sourceForm
        self.inflectionKind = inflectionKind
        self.expectedPartOfSpeech = expectedPartOfSpeech
        self.lookupResult = lookupResult
    }
}

public struct ResolvedLookupService: Sendable {
    private let lookup: @Sendable (String, DictionaryLookupSource) async throws -> LookupResult

    public init(
        lookup: @escaping @Sendable (String, DictionaryLookupSource) async throws -> LookupResult = { term, source in
            try SystemDictionaryClient().lookup(term, source: source, includeSource: false)
        }
    ) {
        self.lookup = lookup
    }

    public func resolve(_ term: String, dictionaryName: String) async throws -> ResolvedLookup {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw LookupError.notFound
        }

        let candidates = LemmaResolver().resolve(query)
        var scored: [(candidate: LemmaCandidate, result: LookupResult, score: Int)] = []

        for candidate in candidates {
            guard let result = try await lookupPreferredResult(for: candidate.lemma, dictionaryName: dictionaryName) else {
                continue
            }

            let score = scoreCandidate(candidate, result: result, originalQuery: query)
            scored.append((candidate, reorder(result, expectedPartOfSpeech: candidate.expectedPartOfSpeech), score))
        }

        guard let best = scored.max(by: { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score < rhs.score
            }
            return lhs.candidate.priority < rhs.candidate.priority
        }) else {
            throw LookupError.notFound
        }

        let preferredHeadword = best.result.entries.first?.headword
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let word = preferredHeadword?.isEmpty == false ? preferredHeadword! : best.candidate.lemma
        let sourceForm = word.caseInsensitiveCompare(query) == .orderedSame ? nil : query

        return ResolvedLookup(
            word: word,
            sourceForm: sourceForm,
            inflectionKind: best.candidate.inflectionKind,
            expectedPartOfSpeech: best.candidate.expectedPartOfSpeech,
            lookupResult: best.result
        )
    }

    private func lookupPreferredResult(for term: String, dictionaryName: String) async throws -> LookupResult? {
        let trimmedDictionaryName = dictionaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackDictionaryName = trimmedDictionaryName.isEmpty
            ? SystemDictionaryClient.defaultDictionaryName
            : trimmedDictionaryName

        do {
            let publicResult = try await lookup(term, .publicAPI)
            if publicResultContainsExamples(publicResult) {
                return publicResult
            }

            if let privateResult = try await lookupPrivate(term, dictionaryName: fallbackDictionaryName) {
                return privateResult
            }

            return publicResult
        } catch LookupError.notFound {
            if let privateResult = try await lookupPrivate(term, dictionaryName: fallbackDictionaryName) {
                return privateResult
            }
            return nil
        }
    }

    private func lookupPrivate(_ term: String, dictionaryName: String) async throws -> LookupResult? {
        do {
            return try await lookup(term, .privateHTML(dictionaryName: dictionaryName))
        } catch LookupError.notFound {
            return nil
        }
    }

    private func publicResultContainsExamples(_ result: LookupResult) -> Bool {
        result.entries.contains { entry in
            entry.lexicalEntries.contains { lexicalEntry in
                lexicalEntry.senses.contains { !$0.examples.isEmpty }
            }
        }
    }

    private func reorder(_ result: LookupResult, expectedPartOfSpeech: PartOfSpeech?) -> LookupResult {
        guard let expectedPartOfSpeech else { return result }

        let reorderedEntries = result.entries.map { entry in
            let lexicalEntries = entry.lexicalEntries.enumerated()
                .sorted { lhs, rhs in
                    let lhsMatches = lhs.element.partOfSpeech == expectedPartOfSpeech
                    let rhsMatches = rhs.element.partOfSpeech == expectedPartOfSpeech
                    if lhsMatches != rhsMatches {
                        return lhsMatches && !rhsMatches
                    }
                    return lhs.offset < rhs.offset
                }
                .enumerated()
                .map { index, tuple in
                    LexicalEntry(
                        partOfSpeech: tuple.element.partOfSpeech,
                        partOfSpeechLabel: tuple.element.partOfSpeechLabel,
                        displayIndex: index,
                        pronunciations: tuple.element.pronunciations,
                        senses: tuple.element.senses,
                        grammar: tuple.element.grammar,
                        inflections: tuple.element.inflections
                    )
                }

            return HeadwordEntry(
                headword: entry.headword,
                pronunciations: entry.pronunciations,
                lexicalEntries: lexicalEntries,
                phraseGroups: entry.phraseGroups,
                notes: entry.notes
            )
        }

        return LookupResult(
            query: result.query,
            entries: reorderedEntries,
            metadata: result.metadata,
            source: result.source
        )
    }

    private func scoreCandidate(_ candidate: LemmaCandidate, result: LookupResult, originalQuery: String) -> Int {
        var score = candidate.priority
        let normalizedQuery = originalQuery.lowercased()
        let normalizedLemma = candidate.lemma.lowercased()

        if result.entries.contains(where: { $0.headword.lowercased() == normalizedLemma }) {
            score += 25
        }

        if result.entries.contains(where: { entry in
            entry.lexicalEntries.contains { lexicalEntry in
                lexicalEntry.inflections.contains { $0.lowercased() == normalizedQuery }
            }
        }) {
            score += 40
        }

        if let expectedPartOfSpeech = candidate.expectedPartOfSpeech,
           result.entries.contains(where: { entry in
               entry.lexicalEntries.contains { $0.partOfSpeech == expectedPartOfSpeech }
           }) {
            score += 20
        }

        if result.entries.contains(where: { entry in
            entry.lexicalEntries.contains { lexicalEntry in
                lexicalEntry.senses.contains { !$0.examples.isEmpty }
            }
        }) {
            score += 10
        }

        if normalizedLemma == normalizedQuery {
            score += 5
        }

        return score
    }
}

struct LemmaResolver {
    func resolve(_ term: String) -> [LemmaCandidate] {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }

        let lexicalHint = lexicalClassHint(for: query)
        var candidates: [LemmaCandidate] = []
        var seen: Set<LemmaCandidateKey> = []

        func addCandidate(
            lemma: String,
            inflectionKind: InflectionKind?,
            expectedPartOfSpeech: PartOfSpeech?,
            priority: Int
        ) {
            let normalizedLemma = lemma.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalizedLemma.isEmpty else { return }
            let key = LemmaCandidateKey(
                lemma: normalizedLemma,
                inflectionKind: inflectionKind,
                expectedPartOfSpeech: expectedPartOfSpeech
            )
            guard seen.insert(key).inserted else { return }
            candidates.append(
                LemmaCandidate(
                    lemma: normalizedLemma,
                    inflectionKind: inflectionKind,
                    expectedPartOfSpeech: expectedPartOfSpeech,
                    priority: priority
                )
            )
        }

        if let lemma = appleLemma(for: query), lemma != query {
            addCandidate(
                lemma: lemma,
                inflectionKind: inferredInflectionKind(for: query, lexicalHint: lexicalHint),
                expectedPartOfSpeech: lexicalHint,
                priority: 45
            )
        }

        if let irregular = Self.irregularForms[query] {
            addCandidate(
                lemma: irregular.lemma,
                inflectionKind: irregular.inflectionKind,
                expectedPartOfSpeech: irregular.expectedPartOfSpeech,
                priority: 40
            )
        }

        addRuleCandidates(for: query, lexicalHint: lexicalHint, addCandidate: addCandidate)
        addCandidate(lemma: query, inflectionKind: nil, expectedPartOfSpeech: lexicalHint, priority: 0)

        return candidates
    }

    private func addRuleCandidates(
        for query: String,
        lexicalHint: PartOfSpeech?,
        addCandidate: (String, InflectionKind?, PartOfSpeech?, Int) -> Void
    ) {
        if query.hasSuffix("ied"), query.count > 3 {
            let stem = String(query.dropLast(3))
            addCandidate("\(stem)y", .pastOrPastParticiple, .verb, 30)
        }

        if query.hasSuffix("ed"), query.count > 2 {
            let stem = String(query.dropLast(2))
            addCandidate(stem, .pastOrPastParticiple, .verb, 28)
            addCandidate("\(stem)e", .pastOrPastParticiple, .verb, 27)
            if let dedoubled = dedoubleLastConsonant(stem) {
                addCandidate(dedoubled, .pastOrPastParticiple, .verb, 29)
            }
        }

        if query.hasSuffix("ing"), query.count > 3 {
            let stem = String(query.dropLast(3))
            addCandidate(stem, .presentParticiple, .verb, 28)
            addCandidate("\(stem)e", .presentParticiple, .verb, 27)
            if let dedoubled = dedoubleLastConsonant(stem) {
                addCandidate(dedoubled, .presentParticiple, .verb, 29)
            }
        }

        if query.hasSuffix("ies"), query.count > 3 {
            let stem = String(query.dropLast(3))
            addCandidate("\(stem)y", .plural, .noun, 26)
            addCandidate("\(stem)y", .thirdPersonSingular, .verb, 24)
        }

        if query.hasSuffix("es"), query.count > 2 {
            let stem = String(query.dropLast(2))
            addCandidate(stem, .plural, .noun, lexicalHint == .verb ? 18 : 22)
            addCandidate(stem, .thirdPersonSingular, .verb, lexicalHint == .verb ? 24 : 18)
            addCandidate("\(stem)e", .thirdPersonSingular, .verb, 19)
        }

        if query.hasSuffix("s"), query.count > 1 {
            let stem = String(query.dropLast())
            addCandidate(stem, .plural, .noun, lexicalHint == .verb ? 14 : 20)
            addCandidate(stem, .thirdPersonSingular, .verb, lexicalHint == .verb ? 22 : 14)
        }

        if query.hasSuffix("est"), query.count > 3 {
            let stem = String(query.dropLast(3))
            let pos = lexicalHint == .adverb ? PartOfSpeech.adverb : .adjective
            addCandidate(stem, .superlative, pos, 24)
            addCandidate("\(stem)e", .superlative, pos, 23)
            if let dedoubled = dedoubleLastConsonant(stem) {
                addCandidate(dedoubled, .superlative, pos, 25)
            }
        }

        if query.hasSuffix("er"), query.count > 2 {
            let stem = String(query.dropLast(2))
            let pos = lexicalHint == .adverb ? PartOfSpeech.adverb : .adjective
            addCandidate(stem, .comparative, pos, 24)
            addCandidate("\(stem)e", .comparative, pos, 23)
            if let dedoubled = dedoubleLastConsonant(stem) {
                addCandidate(dedoubled, .comparative, pos, 25)
            }
        }
    }

    private func dedoubleLastConsonant(_ stem: String) -> String? {
        guard stem.count >= 2 else { return nil }
        let chars = Array(stem)
        let last = chars[chars.count - 1]
        let previous = chars[chars.count - 2]
        guard last == previous else { return nil }
        guard !"aeiou".contains(last) else { return nil }
        return String(chars.dropLast())
    }

    private func inferredInflectionKind(for query: String, lexicalHint: PartOfSpeech?) -> InflectionKind? {
        if Self.irregularForms[query] != nil {
            return Self.irregularForms[query]?.inflectionKind
        }
        if query.hasSuffix("ing") { return .presentParticiple }
        if query.hasSuffix("ed") || query.hasSuffix("ied") { return .pastOrPastParticiple }
        if query.hasSuffix("est") { return .superlative }
        if query.hasSuffix("er") { return .comparative }
        if query.hasSuffix("ies") || query.hasSuffix("es") || query.hasSuffix("s") {
            return lexicalHint == .verb ? .thirdPersonSingular : .plural
        }
        return .unknownDerivedForm
    }

    private func lexicalClassHint(for query: String) -> PartOfSpeech? {
        #if canImport(NaturalLanguage)
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = query
        tagger.setLanguage(.english, range: query.startIndex..<query.endIndex)
        let rawValue = tagger.tag(at: query.startIndex, unit: .word, scheme: .lexicalClass).0?.rawValue
        #else
        let rawValue: String? = nil
        #endif

        switch rawValue?.lowercased() {
        case "verb":
            return .verb
        case "noun":
            return .noun
        case "adjective":
            return .adjective
        case "adverb":
            return .adverb
        default:
            return nil
        }
    }

    private func appleLemma(for query: String) -> String? {
        #if canImport(NaturalLanguage)
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = query
        tagger.setLanguage(.english, range: query.startIndex..<query.endIndex)
        let lemma = tagger.tag(at: query.startIndex, unit: .word, scheme: .lemma).0?.rawValue
        let cleaned = lemma?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned?.isEmpty == false ? cleaned : nil
        #else
        return nil
        #endif
    }

    private static let irregularForms: [String: (lemma: String, inflectionKind: InflectionKind, expectedPartOfSpeech: PartOfSpeech)] = [
        "went": ("go", .pastOrPastParticiple, .verb),
        "gone": ("go", .pastOrPastParticiple, .verb),
        "ran": ("run", .pastOrPastParticiple, .verb),
        "ate": ("eat", .pastOrPastParticiple, .verb),
        "done": ("do", .pastOrPastParticiple, .verb),
        "did": ("do", .pastOrPastParticiple, .verb),
        "better": ("good", .comparative, .adjective),
        "best": ("good", .superlative, .adjective),
        "worse": ("bad", .comparative, .adjective),
        "worst": ("bad", .superlative, .adjective),
    ]
}

struct LemmaCandidate: Equatable {
    let lemma: String
    let inflectionKind: InflectionKind?
    let expectedPartOfSpeech: PartOfSpeech?
    let priority: Int
}

private struct LemmaCandidateKey: Hashable {
    let lemma: String
    let inflectionKind: InflectionKind?
    let expectedPartOfSpeech: PartOfSpeech?
}
