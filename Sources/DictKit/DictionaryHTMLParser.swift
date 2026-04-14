import Foundation
import SwiftSoup

public enum DictionaryHTMLParser {
    public static func parse(query: String, html: String, includeSource: Bool) throws -> LookupResult {
        guard let doc = try? SwiftSoup.parse(html) else {
            throw LookupError.parseFailed
        }

        let headword = ((try? doc.select("span.hw").first()?.ownText()) ?? query)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let headwordPronunciations = parsePronunciations(in: doc)
        var lexicalEntries: [LexicalEntry] = []
        var phraseGroups: [PhraseGroup] = []
        var notes: [Note] = []

        let senseGroups = (try? doc.select("span.sg").array()) ?? []
        for senseGroup in senseGroups {
            let units = (try? senseGroup.select("> span.se1").array()) ?? []
            let lexicalUnits = units.isEmpty ? [senseGroup] : units

            for unit in lexicalUnits {
                let partOfSpeechLabel = ((try? unit.select("span.posg span.pos").first()?.text()) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                guard !partOfSpeechLabel.isEmpty else {
                    continue
                }

                let senses = parseSenses(in: unit)
                lexicalEntries.append(
                    LexicalEntry(
                        partOfSpeech: mapPartOfSpeech(from: partOfSpeechLabel),
                        partOfSpeechLabel: partOfSpeechLabel,
                        displayIndex: lexicalEntries.count,
                        pronunciations: headwordPronunciations,
                        senses: senses.isEmpty ? [
                            Sense(
                                number: 1,
                                semanticHint: nil,
                                definition: (try? unit.text()) ?? "",
                                examples: [],
                                registers: [],
                                countability: nil
                            )
                        ] : senses,
                        grammar: parseGrammar(in: unit),
                        inflections: parseInflections(in: unit)
                    )
                )
            }
        }

        let subEntryBlocks = (try? doc.select("span.subEntryBlock").array()) ?? []
        for block in subEntryBlocks {
            let title = ((try? block.select("span.gp.tg_subEntryBlock").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                continue
            }

            let items = ((try? block.select("> span.subEntry").array()) ?? []).compactMap(parsePhraseItem(from:))
            if !items.isEmpty {
                phraseGroups.append(PhraseGroup(title: title, items: items, rawContent: nil))
            } else {
                let content = ((try? block.text()) ?? "")
                    .replacingOccurrences(of: title, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                phraseGroups.append(PhraseGroup(title: title, items: [], rawContent: content.isEmpty ? nil : content))
            }
        }

        if let usage = try? doc.select("span.note.x_xo0").first(),
           let usageText = try? usage.text() {
            let cleaned = usageText.replacingOccurrences(of: "USAGE", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                notes.append(Note(kind: .usage, content: cleaned))
            }
        }

        if let etymology = try? doc.select("span.etym.x_xo0").first(),
           let etymologyText = try? etymology.text() {
            let cleaned = etymologyText.replacingOccurrences(of: "ORIGIN", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                notes.append(Note(kind: .etymology, content: cleaned))
            }
        }

        guard !lexicalEntries.isEmpty || !phraseGroups.isEmpty || !notes.isEmpty else {
            throw LookupError.parseFailed
        }

        return LookupResult(
            query: query,
            entries: [
                HeadwordEntry(
                    headword: headword.isEmpty ? query : headword,
                    pronunciations: headwordPronunciations,
                    lexicalEntries: lexicalEntries,
                    phraseGroups: phraseGroups,
                    notes: notes
                )
            ],
            metadata: LookupMetadata(usedSource: .privateHTML, warnings: []),
            source: includeSource ? SourcePayload(rawText: nil, rawHTML: html) : nil
        )
    }

    private static func parsePronunciations(in doc: Document) -> [Pronunciation] {
        let hg = (try? doc.select("span.hg, span.prx").first())
        let respellings = (try? hg?.select("span.ph.t_respell").array()) ?? []
        var pronunciations: [Pronunciation] = []

        for span in respellings {
            let respelling = ((try? span.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !respelling.isEmpty else {
                continue
            }

            let dialect = ((try? span.attr("dialect")) ?? "").nilIfEmpty ?? ((try? span.attr("d:prn")) ?? "").nilIfEmpty
            pronunciations.append(
                Pronunciation(
                    dialect: normalizedDialect(from: dialect),
                    ipa: normalizePronunciationToken(respelling),
                    respelling: normalizePronunciationToken(respelling)
                )
            )
        }

        if pronunciations.isEmpty {
            let prnSpans = (try? doc.select("[d|prn]").array()) ?? []
            for span in prnSpans {
                let raw = ((try? span.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else {
                    continue
                }

                pronunciations.append(
                    Pronunciation(
                        dialect: normalizedDialect(from: ((try? span.attr("d:prn")) ?? "").nilIfEmpty),
                        ipa: normalizePronunciationToken(raw),
                        respelling: normalizePronunciationToken(raw)
                    )
                )
            }
        }

        return deduplicatedPronunciations(pronunciations)
    }

    private static func parseSenses(in unit: Element) -> [Sense] {
        let blocks = (try? unit.select("span.se2 > span.msDict, span.se2 span.msDict.x_xd1sub, span.se2 span.msDict.x_xo2sub, span.se2 span.msDict.t_core").array()) ?? []
        var senses: [Sense] = []

        for block in blocks {
            let definition = normalizeWhitespace(((try? block.select("> span.df").first()?.text()) ?? (try? block.select("span.df").first()?.text()) ?? ""))
            guard !definition.isEmpty else {
                continue
            }

            let examples = ((try? block.select("span.eg span.ex").array()) ?? []).compactMap { example in
                let text = ((try? example.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }

            let registers = ((try? block.select("span.reg, span.ge, span.sj").array()) ?? []).compactMap { node in
                let text = ((try? node.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }

            let grammar = ((try? block.select("span.gg").array()) ?? []).compactMap { node in
                let text = ((try? node.text()) ?? "")
                    .replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }

            let semanticHint: String?
            if definition.hasPrefix("("), let end = definition.firstIndex(of: ")") {
                semanticHint = String(definition[...end])
            } else {
                semanticHint = nil
            }

            let cleanedDefinition = semanticHint.map {
                String(definition.dropFirst($0.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? definition

            senses.append(
                Sense(
                    number: senses.count + 1,
                    semanticHint: semanticHint,
                    definition: cleanedDefinition,
                    examples: examples,
                    registers: registers + grammar,
                    countability: nil
                )
            )
        }

        return senses
    }

    private static func parseGrammar(in unit: Element) -> [String] {
        let grammar = ((try? unit.select("span.gg").array()) ?? []).compactMap { node in
            let text = ((try? node.text()) ?? "")
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return grammar.uniqued()
    }

    private static func parseInflections(in unit: Element) -> [String] {
        let inflections = ((try? unit.select("span.infg span.inf").array()) ?? []).compactMap { node in
            let text = ((try? node.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return inflections.uniqued()
    }

    private static func parsePhraseItem(from node: Element) -> PhraseItem? {
        let phrase = (((try? node.select("> span.l").first()?.ownText()) ?? (try? node.select("> span.l").first()?.text())) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            return nil
        }

        let definitions = ((try? node.select("span.df").array()) ?? []).compactMap { df in
            let text = ((try? df.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        let examples = ((try? node.select("span.eg span.ex").array()) ?? []).compactMap { ex in
            let text = ((try? ex.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        return PhraseItem(phrase: phrase, definition: definitions.first, examples: examples)
    }

    private static func normalizedDialect(from raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "ame", "us", "american english":
            return "AmE"
        case "bre", "uk", "british english":
            return "BrE"
        case let value? where !value.isEmpty:
            return raw
        default:
            return nil
        }
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let self else { return nil }
        return self.isEmpty ? nil : self
    }
}
