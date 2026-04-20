import Foundation

/// Builds the `structuredJSON` half of a `CardRenderSnapshot` for Standard
/// cards.
///
/// The output is a single-line JSON string with sorted keys, so tests can use
/// a plain-text snapshot comparison and the Agent sees a stable shape. Schema
/// stays in lockstep with §4.4.3 of the Agent Chat spec.
enum StandardStructuredJSONRenderer {
    static func render(
        word: String,
        phonetic: String,
        senses: [StructuredSense],
        artifacts: AIArtifacts
    ) -> String {
        let payload = StandardCardPayload(
            kind: "standard",
            word: word,
            phonetic: phonetic,
            senses: senses.map { sense in
                StandardCardPayload.Sense(
                    id: sense.id,
                    pos: sense.partOfSpeech,
                    semanticHint: sense.semanticHint,
                    registers: sense.registers.isEmpty ? nil : sense.registers,
                    definition: sense.definition,
                    examples: sense.examples
                )
            },
            artifacts: StandardCardPayload.Artifacts(
                examples: (artifacts.exampleSentences.accepted ?? []).enumerated().map { index, example in
                    StandardCardPayload.Example(
                        id: "ex-\(index + 1)",
                        text: example.text,
                        translation: example.translation,
                        note: example.note
                    )
                },
                usageCue: artifacts.definitionNote.accepted.map {
                    StandardCardPayload.UsageCue(text: $0.text)
                },
                pitfalls: (artifacts.pitfalls.accepted ?? []).enumerated().map { index, pitfall in
                    StandardCardPayload.Pitfall(
                        id: pitfall.id ?? "pf-\(index + 1)",
                        text: pitfall.text,
                        translation: pitfall.translation,
                        category: pitfall.category
                    )
                },
                mnemonics: (artifacts.mnemonics.accepted ?? []).enumerated().map { index, mnemonic in
                    StandardCardPayload.Mnemonic(
                        id: mnemonic.id ?? "mn-\(index + 1)",
                        text: mnemonic.text,
                        translation: mnemonic.translation,
                        kind: mnemonic.kind
                    )
                },
                collocations: (artifacts.collocations.accepted ?? []).enumerated().map { index, collocation in
                    StandardCardPayload.Collocation(
                        id: collocation.id ?? "co-\(index + 1)",
                        phrase: collocation.phrase,
                        note: collocation.note
                    )
                }
            )
        )

        return encode(payload)
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

private struct StandardCardPayload: Encodable {
    let kind: String
    let word: String
    let phonetic: String
    let senses: [Sense]
    let artifacts: Artifacts

    struct Sense: Encodable {
        let id: String
        let pos: String
        let semanticHint: String?
        let registers: [String]?
        let definition: String
        let examples: [String]

        private enum CodingKeys: String, CodingKey {
            case id
            case pos
            case semanticHint
            case registers
            case definition
            case examples
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(pos, forKey: .pos)
            try c.encodeIfPresent(semanticHint, forKey: .semanticHint)
            try c.encodeIfPresent(registers, forKey: .registers)
            try c.encode(definition, forKey: .definition)
            try c.encode(examples, forKey: .examples)
        }
    }

    struct Artifacts: Encodable {
        let examples: [Example]
        let usageCue: UsageCue?
        let pitfalls: [Pitfall]
        let mnemonics: [Mnemonic]
        let collocations: [Collocation]

        private enum CodingKeys: String, CodingKey {
            case examples
            case usageCue
            case pitfalls
            case mnemonics
            case collocations
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(examples, forKey: .examples)
            try c.encodeIfPresent(usageCue, forKey: .usageCue)
            try c.encode(pitfalls, forKey: .pitfalls)
            try c.encode(mnemonics, forKey: .mnemonics)
            try c.encode(collocations, forKey: .collocations)
        }
    }

    struct Example: Encodable {
        let id: String
        let text: String
        let translation: String?
        let note: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(translation, forKey: .translation)
            try c.encodeIfPresent(note, forKey: .note)
        }

        private enum Keys: String, CodingKey { case id, text, translation, note }
    }

    struct UsageCue: Encodable {
        let text: String
    }

    struct Pitfall: Encodable {
        let id: String
        let text: String
        let translation: String?
        let category: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(translation, forKey: .translation)
            try c.encodeIfPresent(category, forKey: .category)
        }

        private enum Keys: String, CodingKey { case id, text, translation, category }
    }

    struct Mnemonic: Encodable {
        let id: String
        let text: String
        let translation: String?
        let kind: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(translation, forKey: .translation)
            try c.encodeIfPresent(kind, forKey: .kind)
        }

        private enum Keys: String, CodingKey { case id, text, translation, kind }
    }

    struct Collocation: Encodable {
        let id: String
        let phrase: String
        let note: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .id)
            try c.encode(phrase, forKey: .phrase)
            try c.encodeIfPresent(note, forKey: .note)
        }

        private enum Keys: String, CodingKey { case id, phrase, note }
    }
}

/// Builds the `structuredJSON` for Recall cards.
enum RecallStructuredJSONRenderer {
    static func render(
        word: String,
        phonetic: String,
        draft: RecallCardDraft?,
        senses: [StructuredSense]
    ) -> String {
        let payload = RecallCardPayload(
            kind: "recall",
            word: word,
            phonetic: phonetic,
            recall: draft.map { draft in
                RecallCardPayload.Recall(
                    mode: draft.mode.rawValue,
                    front: draft.front,
                    back: draft.back,
                    hint: draft.hint
                )
            },
            reference: senses.map { sense in
                RecallCardPayload.ReferenceSense(
                    id: sense.id,
                    pos: sense.partOfSpeech,
                    definition: sense.definition
                )
            }
        )
        return StandardStructuredJSONRenderer.encode(payload)
    }
}

private struct RecallCardPayload: Encodable {
    let kind: String
    let word: String
    let phonetic: String
    let recall: Recall?
    let reference: [ReferenceSense]

    struct Recall: Encodable {
        let mode: String
        let front: String
        let back: String
        let hint: String?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(mode, forKey: .mode)
            try c.encode(front, forKey: .front)
            try c.encode(back, forKey: .back)
            try c.encodeIfPresent(hint, forKey: .hint)
        }

        private enum Keys: String, CodingKey { case mode, front, back, hint }
    }

    struct ReferenceSense: Encodable {
        let id: String
        let pos: String
        let definition: String
    }
}
