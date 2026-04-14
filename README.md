# macos-dictkit

`macos-dictkit` is a Swift package for querying the macOS built-in Dictionary app and turning its raw payloads into structured, program-friendly models.

It exposes a parser-focused core library, an opt-in macOS system dictionary client, and a small CLI for ad-hoc inspection.

## Features

- Parse `DCSCopyTextDefinition` output into structured lexical entries, senses, phrase groups, and notes.
- Parse private HTML dictionary payloads when the private source is available on the current macOS build.
- Query the active system dictionaries through a dedicated macOS-only client module.
- Inspect results from the terminal with either human-readable or JSON output.

## Modules

- `DictKit`: Parser models and parsing logic.
- `DictKitSystemDictionary`: macOS-only lookup client built on Dictionary Services and the private HTML bridge.
- `dictkit`: Command-line executable.

## Requirements

- macOS 10.15 or later
- Swift 5.9 or later

## Usage

Use the parser module when you already have raw payloads:

```swift
import DictKit

let result = try DictionaryTextParser.parse(
    query: "apple",
    raw: rawText,
    includeSource: false
)
```

Use the system dictionary module for live lookups on macOS:

```swift
import DictKit

#if canImport(DictKitSystemDictionary)
import DictKitSystemDictionary

let client = SystemDictionaryClient()
let result = try client.lookup("apple", source: .automatic, includeSource: true)
#endif
```

## CLI

```bash
swift run dictkit apple
swift run dictkit --json apple
swift run dictkit --html-json run
swift run dictkit --raw-html run
swift run dictkit --list-dicts
```

## Development

Run the full test suite:

```bash
swift test
```

Build the CLI:

```bash
swift build --product dictkit
```

## Notes

- The public Dictionary Services API returns flattened definition text rather than a stable structured schema.
- The private HTML source is useful in practice, but it is not an officially supported API contract from Apple.
