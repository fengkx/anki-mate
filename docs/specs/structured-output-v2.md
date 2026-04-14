# Structured Output V2 Proposal

## 1. Scope

This document proposes a v2 public data model for dictionary lookup results.

It intentionally starts from the application developer's point of view rather than
from the current parser shape. The goal is not to incrementally patch
`DictionaryEntry` / `DictionaryBlock`, but to define a stable public contract that:

- models lexical data instead of parser artifacts;
- stays consistent across public and private lookup paths;
- exposes uncertainty explicitly;
- remains evolvable without forcing downstream apps to re-parse strings.

This document does not prescribe parser internals. It defines the public SDK
surface and the compatibility strategy around it.

---

## 2. Design Principles

### 2.1 Model the domain, not the extraction process

Application developers care about headwords, pronunciations, parts of speech,
senses, examples, phrases, and usage labels.

They do not care whether the SDK happened to extract a section as:

- `partOfSpeech`
- `specialSection`
- `fallback`
- `unknown`

Those concepts are parser concerns. They may still exist internally, but they
should not be the center of the public API.

### 2.2 Keep the contract source-agnostic

The same logical field must have the same shape regardless of where the data
comes from.

For example, pronunciations must not differ between:

- the `DCSCopyTextDefinition` path;
- the private HTML path.

If the SDK exposes one public model, the SDK owns normalization.

### 2.3 Separate semantic data from debug data

Consumers should not have to guess whether `content` or `senses` is the real
source of truth.

The semantic model should be primary. Raw parser output should live in a
separate debug/source namespace.

### 2.4 Express uncertainty explicitly

Dictionary extraction is heuristic by nature. The public API should distinguish:

- value is absent in source data;
- value exists but could not be parsed;
- value is parsed with low confidence.

An empty array or empty string is not enough to represent these cases.

### 2.5 Prefer stable structs over parser-shaped sum types

For a public Swift SDK, a tree of stable `struct`s plus small enums is easier to:

- evolve safely;
- encode/decode;
- document;
- consume from JSON;
- bridge across module boundaries.

Associated-value enums are powerful, but they tend to make long-term public
schema evolution harder.

---

## 3. Problems in the Current Direction

The current improvement spec moves in the right direction, but it still keeps
`DictionaryBlock` as the primary abstraction. That remains a design smell.

### 3.1 `DictionaryBlock` is still parser-centric

`label`, `kind`, `name`, `content`, `senses`, `grammar`, and `inflections`
mix multiple abstraction levels in one type:

- presentation metadata (`label`);
- classification metadata (`kind`);
- semantic identity (`name`);
- structured data (`senses`);
- residual raw text (`content`);
- grammar extras (`grammar`, `inflections`).

This makes the type broad, ambiguous, and likely to keep growing.

### 3.2 `specialSection` is too vague

The following are not the same kind of thing:

- `ORIGIN`
- `PHRASES`
- `PHRASAL VERBS`
- `DERIVATIVES`
- cross references

Treating them as one generic bucket pushes classification burden onto the app.

### 3.3 `content` remains a contract hazard

As long as `content` remains a top-level field beside structured fields,
consumers will ask:

- Should I render `content`?
- Is `content` authoritative?
- Can `content` disagree with `senses`?

That ambiguity should be removed at the contract level.

### 3.4 `label` is presentation data, not domain data

`A`, `B`, `C` labels are useful for mirroring Dictionary.app style, but they
should not act as a semantic grouping primitive.

They may be retained as optional display metadata, but should not anchor the
data model.

---

## 4. Proposed V2 Public Model

### 4.1 Top-level result

```swift
public struct LookupResult: Codable, Equatable, Sendable {
    public let query: String
    public let entries: [HeadwordEntry]
    public let diagnostics: [ParseDiagnostic]
    public let source: SourcePayload?
}
```

Rationale:

- `query` preserves what the caller asked for.
- `entries` allows future support for multiple matches or dictionary variants.
- `diagnostics` surfaces partial parsing and normalization issues.
- `source` contains raw/debug material and is not the main API path.

### 4.2 Headword entry

```swift
public struct HeadwordEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let lemma: String
    public let displayHeadword: String
    public let pronunciations: [Pronunciation]
    public let lexicalEntries: [LexicalEntry]
    public let phrases: [PhraseEntry]
    public let notes: [EntryNote]
}
```

Rationale:

- `lemma` is the normalized lexical form.
- `displayHeadword` preserves the user-facing title when formatting differs.
- `phrases` are first-class data, not a special section bucket.
- `notes` handles etymology, usage notes, references, and similar auxiliary data.

### 4.3 Lexical entry

```swift
public struct LexicalEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let partOfSpeech: PartOfSpeech
    public let pronunciations: [Pronunciation]
    public let grammar: GrammarInfo?
    public let inflections: [Inflection]
    public let senses: [Sense]
    public let displayIndex: Int?
}
```

Rationale:

- A lexical entry is the correct home for one POS-specific slice.
- Per-entry pronunciations handle cases like `elaborate`, where adjective and
  verb have different pronunciations.
- `displayIndex` can support `A/B/C`-style rendering without making that
  concept part of the semantic core.

### 4.4 Sense

```swift
public struct Sense: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let number: Int?
    public let gloss: String
    public let translations: [Translation]
    public let examples: [Example]
    public let usageLabels: [UsageLabel]
    public let semanticLabel: String?
    public let countability: Countability?
    public let subsenses: [Sense]
}
```

Rationale:

- `gloss` is the canonical meaning text for the sense.
- `translations` allows structured downstream rendering of CJK text and pinyin.
- `examples` should be structured now, not later.
- `semanticLabel` captures hints like `(brightness)` without polluting `gloss`.
- `subsenses` avoids flattening all sense hierarchy.

### 4.5 Phrase entry

```swift
public struct PhraseEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let phrase: String
    public let senses: [Sense]
}
```

Rationale:

- Phrases behave like mini headword entries.
- Apps often want to show phrases separately from the main POS tree.

### 4.6 Entry notes

```swift
public struct EntryNote: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: EntryNoteKind
    public let title: String?
    public let content: String
    public let targets: [ReferenceTarget]
}

public enum EntryNoteKind: String, Codable, Sendable {
    case etymology
    case usage
    case derivative
    case phrasalVerb
    case reference
    case abbreviation
    case other
}
```

Rationale:

- `ORIGIN` is an etymology note, not a dictionary block.
- cross references should not be represented as raw strings only.

---

## 5. Supporting Types

### 5.1 Pronunciation

```swift
public struct Pronunciation: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let dialect: Dialect?
    public let ipa: String
    public let respelling: String?
    public let audio: AudioResource?
}
```

Key point:

- `ipa` is always normalized and never includes wrapper punctuation.
- dialect is structured metadata, not embedded in the text.

```swift
public enum Dialect: Codable, Equatable, Sendable {
    case british
    case american
    case other(String)
}

public struct AudioResource: Codable, Equatable, Sendable {
    public let url: URL
    public let format: String?
}
```

### 5.2 Translation

```swift
public struct Translation: Codable, Equatable, Sendable {
    public let text: String
    public let reading: String?
    public let language: String?
}
```

This is intentionally broader than `pinyin`, because the SDK may later need to
support other bilingual dictionaries or alternate reading systems.

### 5.3 Example

```swift
public struct Example: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let translation: String?
    public let usageLabels: [UsageLabel]
}
```

This avoids getting trapped in `[String]` and having to break the API later.

### 5.4 Usage label

```swift
public enum UsageLabel: Codable, Equatable, Sendable {
    case formal
    case informal
    case literary
    case archaic
    case dated
    case rare
    case humorous
    case figurative
    case ironic
    case euphemistic
    case derogatory
    case offensive
    case technical
    case dialect
    case vulgar
    case other(String)
}
```

This keeps common labels type-safe while preserving forward compatibility.

### 5.5 Countability

```swift
public enum Countability: String, Codable, Sendable {
    case countable
    case uncountable
    case countableAndUncountable
}
```

### 5.6 Part of speech

```swift
public enum PartOfSpeech: Codable, Equatable, Sendable {
    case noun
    case verb
    case adjective
    case adverb
    case pronoun
    case determiner
    case preposition
    case conjunction
    case interjection
    case abbreviation
    case combiningForm
    case other(String)
}
```

Using `.other(String)` is important. Dictionary data looks finite until it
doesn't.

### 5.7 Grammar and inflection

```swift
public struct GrammarInfo: Codable, Equatable, Sendable {
    public let patterns: [GrammarPattern]
}

public enum GrammarPattern: Codable, Equatable, Sendable {
    case noObject
    case withObject
    case withAdverbial
    case withClause
    case other(String)
}

public struct Inflection: Codable, Equatable, Sendable {
    public let form: String
    public let label: InflectionLabel?
}

public enum InflectionLabel: String, Codable, Sendable {
    case plural
    case past
    case pastParticiple
    case presentParticiple
    case thirdPersonSingular
}
```

### 5.8 Reference target

```swift
public struct ReferenceTarget: Codable, Equatable, Sendable {
    public let text: String
    public let targetID: String?
}
```

---

## 6. Uncertainty and Diagnostics

This is the part the current spec is still missing.

### 6.1 Diagnostics must be first-class

```swift
public struct ParseDiagnostic: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let severity: DiagnosticSeverity
    public let code: String
    public let message: String
    public let path: String?
}

public enum DiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}
```

Examples:

- a sense boundary was inferred heuristically;
- phrase definitions were unavailable in the current source;
- a pronunciation was normalized from inconsistent source formatting;
- a section was preserved only in raw/source payload.

### 6.2 Source payload should be opt-in

```swift
public struct SourcePayload: Codable, Equatable, Sendable {
    public let rawText: String?
    public let rawHTML: String?
    public let parserFragments: [String: String]
}
```

This keeps debugging possible without polluting the main semantic contract.

---

## 7. API Surface

### 7.1 Primary lookup API

```swift
public struct LookupOptions: Sendable {
    public let preferredSource: PreferredSource
    public let includeSourcePayload: Bool
    public let detailLevel: DetailLevel
}

public enum PreferredSource: Sendable {
    case publicAPIOnly
    case privateHTMLPreferred
    case automatic
}

public enum DetailLevel: Sendable {
    case minimal
    case standard
    case extended
}

public func lookup(_ term: String, options: LookupOptions = .default) async throws -> LookupResult
```

Key point:

- The app should ask for desired behavior.
- The SDK should own source selection and normalization.

### 7.2 Why not expose separate public/private result types?

Because the caller is asking for lexical data, not for parser provenance.

Source-specific APIs may still exist internally or in debugging tools, but the
primary SDK contract should remain normalized.

---

## 8. Compatibility Strategy

### 8.1 Keep v1 intact during transition

Do not silently mutate the meaning of existing public fields.

Instead:

- keep `DictionaryEntry` / `DictionaryBlock` available in v1;
- introduce the new model under a separate v2 API;
- provide explicit adapters where possible.

### 8.2 Introduce adapters

```swift
public extension LookupResult {
    func asLegacyDictionaryEntry() -> DictionaryEntry
}
```

This allows existing CLI output and tests to migrate incrementally.

### 8.3 Deprecation policy

Only deprecate v1 after:

- v2 covers the common rendering and JSON export use cases;
- snapshot tests exist for both public and private source paths;
- downstream apps have a clear migration guide.

### 8.4 Stable identity

IDs do not need to be globally permanent forever, but they should be stable
within a major SDK version for the same normalized content.

That is enough for:

- bookmarks;
- per-sense UI state;
- diffing;
- cached rendering.

---

## 9. Mapping from Current Concepts to V2

| Current concept | V2 destination |
|----------------|----------------|
| `DictionaryEntry.query` | `LookupResult.query` |
| `DictionaryEntry.headword` | `HeadwordEntry.lemma` / `displayHeadword` |
| `DictionaryEntry.pronunciations: [String]` | `[Pronunciation]` |
| `DictionaryEntry.entries` | `HeadwordEntry.lexicalEntries` + `phrases` + `notes` |
| `DictionaryBlock.kind == partOfSpeech` | `LexicalEntry` |
| `DictionaryBlock.kind == phrase` | `PhraseEntry` |
| `DictionaryBlock.kind == specialSection` | usually `EntryNote`, sometimes `PhraseEntry` |
| `DictionaryBlock.content` | structured fields or `SourcePayload` |
| `rawText` | `SourcePayload.rawText` |

---

## 10. Non-Goals

V2 should not try to guarantee:

- lossless reconstruction of Dictionary.app layout;
- perfect linguistic analysis for every entry;
- full fidelity for every private HTML detail from day one.

The public contract should optimize for application usefulness, not for perfect
mirroring of the underlying source.

---

## 11. Recommendation

Do not continue iterating on `DictionaryBlock` as the primary public model.

Recommended path:

1. Keep the current parser-oriented model as v1 compatibility output.
2. Introduce `LookupResult -> HeadwordEntry -> LexicalEntry -> Sense` as the v2
   semantic model.
3. Move raw and lossy parser artifacts under an opt-in debug/source namespace.
4. Make uncertainty visible through diagnostics instead of hiding it behind
   empty strings and fallback buckets.

This gives the SDK a cleaner public contract, reduces downstream re-parsing, and
creates room for future parser improvements without repeated schema churn.
