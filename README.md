# Anki Mate

Anki Mate is a macOS study companion that helps you turn words you encounter into review-ready material.

It combines system dictionary lookup, pronunciation audio, local-first study workflows, and optional on-device AI features into a single desktop app.

## Features

- Look up words from the macOS built-in dictionaries and keep structured results for later review.
- Generate pronunciation audio from dictionary-backed pronunciations.
- Organize saved words into a local study workflow designed for export to Anki.
- Support local AI-assisted study features through the bundled on-device inference stack.

## Requirements

- macOS 10.15 or later
- Swift 5.9 or later

## Run Locally

Build the app:

```bash
swift build --product anki-mate
```

Launch the app through the repo workflow:

```bash
just run-app
```

## Development

This repository still contains several internal modules and tools that power Anki Mate:

- `DictKit`: parsing and lexical model layer
- `DictKitSystemDictionary`: macOS dictionary and speech integration
- `DictKitAnkiExport`: Anki export pipeline
- `dictkit`: internal CLI for parser and dictionary inspection
- `AnkiMateServer`: local inference server used by AI features

Useful commands:

```bash
just build
just test
just lookup apple
just lookup-json apple
just test-filter WordListViewModelTests
```

If you need the inspection CLI directly:

```bash
swift run dictkit apple
swift run dictkit --json apple
swift run dictkit speech --output ./apple.wav apple
```

## Notes

- The app uses Apple's Dictionary Services and related system data sources, which do not expose a stable public structured schema.
- Some lookup and parsing capabilities rely on behavior that is useful in practice but not guaranteed by Apple as a long-term API contract.
