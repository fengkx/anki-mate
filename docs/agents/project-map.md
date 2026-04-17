# Project Map

Use this file when you need to orient yourself in the codebase and choose the right entry point.

## Product Layout

### `dictkit`

- Target path: `Sources/DictKitCLI`, `Sources/DictKitExecutable`
- Purpose: parser inspection, dictionary lookup, HTML/raw output, speech synthesis entry points
- Use first for:
  - parser regressions
  - dictionary lookup behavior
  - speech request resolution
  - quick fixture-free debugging

### `anki-mate`

- Target path: `Sources/DictKitApp`
- Purpose: macOS app for word collection, export, sync, and AI-assisted content
- Main areas:
  - `Models`: app-facing state objects such as `WordItem`
  - `Persistence`: local snapshots and SQLite-backed store
  - `Sync`: WebDAV client, manifest merge, scheduler, sync status
  - `ViewModels`: `WordListViewModel` is the central app state owner
  - `Views`: SwiftUI surfaces

### `AnkiMateLLM`

- Target path: `Sources/AnkiMateLLM`
- Purpose: model registry, downloads, RPC, and local server process management
- Start here for:
  - model download progress bugs
  - installed/downloaded model state mismatches
  - server bootstrap or RPC issues

### `AnkiMateServer`

- Target path: `Sources/AnkiMateServer`
- Purpose: local inference server linked against vendored `llama.cpp`
- Notes:
  - not available in a fresh checkout until `just build-llama` has produced `vendor/llama-install`
  - test builds currently pull this target into the graph

## Dependency Shape

- Core parsing lives in `DictKit`
- macOS system integration lives in `DictKitSystemDictionary`
- App depends on `DictKit`, `DictKitSystemDictionary`, `DictKitAnkiExport`, `AnkiMateLLM`
- Inference server depends on `AnkiMateRPC`, `CllmLibrary`, and `swift-nio`

This means app-level test or build failures can be caused by LLM/server linkage even if the edited code is in UI or persistence.

## Where To Start By Problem Type

### Parser output is wrong

- Start in `Sources/DictKit`
- Validate with `just lookup-json <word>`
- Then inspect `Tests/DictKitTests/StructuredOutputTests.swift` and `FinalSnapshotTests.swift`

### CLI behavior is wrong

- Start in `Sources/DictKitCLI`
- Validate with `just run ...`
- Then inspect `Tests/DictKitTests/CLISmokeTests.swift` and `DictKitCommandTests.swift`

### Speech behavior is wrong

- Start in `Sources/DictKitSystemDictionary/DictionarySpeechClient.swift`
- Inspect `SpeechVoiceResolver.swift` and `SpeechAudioEncoder.swift`
- Check `Tests/DictKitTests/DictionarySpeechClientTests.swift` and related speech tests

### App list, collection, export, or sync behavior is wrong

- Start in `Sources/DictKitApp/ViewModels/WordListViewModel.swift`
- Then inspect:
  - `Persistence/WordListStore.swift`
  - `Sync/SyncEngine.swift`
  - `Sync/WordListStore+Sync.swift`
  - relevant SwiftUI view under `Views/`

### Model download or AI content behavior is wrong

- Start in:
  - `Sources/AnkiMateLLM/LLMService.swift`
  - `Sources/AnkiMateLLM/ModelDownloadManager.swift`
  - `Sources/DictKitApp/Views/LLMSettingsView.swift`
  - `Sources/DictKitApp/Views/AIContentView.swift`

## Test Layout

- `Tests/DictKitTests`: parser, CLI, system dictionary, speech
- `Tests/DictKitAppTests`: app persistence, view model, state propagation, LLM bridging
- `Tests/AnkiExportTests`: export formatting and packaging

When fixing a bug, add the test near the owning layer rather than only adding a broad integration test.
