# Testing Guide

Use this file to choose the smallest useful test loop and avoid false negatives.

## Important Constraint

Today, `swift test` pulls `AnkiMateServer` into the build graph. That means:

- `just test` requires `vendor/llama-install`
- if llama headers or dylibs are missing, tests fail before exercising unrelated app code

So the first triage question is: is this a real regression, or a missing llama build prerequisite?

## Default Test Commands

```bash
just test
just test-verbose
just test-filter WordListViewModelTests
just test-llm
just test-core
just test-anki
just test-speech
```

## Recommended Test Selection By Change Type

### Parser / dictionary lookup

- `just test-core`
- often enough:
  - `StructuredOutputTests`
  - `FinalSnapshotTests`
  - `ResolvedLookupServiceTests`

### CLI changes

- `just test-filter CLISmoke`
- `just test-filter DictKitCommandTests`

### Speech changes

- `just test-filter Speech`
- enable integration-only flows with `DICTKIT_RUN_SPEECH_TESTS=1`

### LLM prompt / inference changes

- `just test-llm`
- `just test-filter LLMPromptTests`
- `just test-filter LLMServiceTests`
- focus coverage:
  - structured JSON prompt shape for recall drafts and learning aids
  - structured-output decoding and normalization
  - auto-start model selection priority (`last successfully loaded` -> `selected` -> first downloaded)
- optional end-to-end run with a downloaded model:
  - first-time setup for the pinned CI model:
    - `just prepare-llm-e2e-model`
  - run the end-to-end suite:
    - `just test-llm-e2e`
  - CI-equivalent local loop:
    - `just ci-llm-e2e`
  - optionally pin a different downloaded model:
    - `DICTKIT_LLM_E2E_MODEL_ID=<model-id> just test-llm-e2e`

The pinned CI model is defined in `ci/llm-e2e-model.lock.json`.
Keep it to a single GGUF by default. GitHub Actions cache is limited and large model churn will evict unrelated caches.

### App persistence / sync / UI state

- `just test-filter WordList`
- inspect:
  - `WordListStoreTests`
  - `WordListViewModelTests`
  - `WordResolutionPersistenceTests`
  - `LLMServiceTests` when state touches AI download or model status

### Export changes

- `just test-anki`
- focused AI artifact contract coverage:
  - `just test-ai-contract`
  - use when touching the unified `AIArtifacts` schema, `RecallCardDraft`, or export formatting for pitfalls / mnemonics / collocations

## State Bug Test SOP

For UI/state bugs, prefer focused view-model or service tests over manual-only verification.

Cover these transitions where relevant:

1. initial load from persistence
2. local mutation updates derived UI immediately
3. external store mutation appears without relaunch
4. async success updates both visible state and persistence
5. async failure leaves a coherent state
6. clear/reset paths persist the cleared value

## When `just test` Is Too Expensive

Use a focused raw `swift test` invocation if you need tighter control, but keep the same cache and llama flags that `justfile` expects.

Typical reasons:

- narrow one failing test suite
- pass explicit include/link flags
- avoid rerunning the entire graph during fast iteration

## GitHub Actions Notes

- General CI now builds `llama.cpp` before `just ci`, so clean macOS runners can execute the full test graph.
- LLM integration tests live in a separate workflow: `.github/workflows/llm-e2e.yml`
- That workflow caches only the pinned model file, not the whole Hugging Face cache tree, to stay within GitHub's cache budget more reliably.
- Cache keys are derived from `ci/llm-e2e-model.lock.json`; change that file intentionally when rotating the model.

## Test Placement Rule

- parser fix -> `Tests/DictKitTests`
- export fix -> `Tests/AnkiExportTests`
- app state or persistence fix -> `Tests/DictKitAppTests`
- model download or server lifecycle fix -> usually `Tests/DictKitAppTests`

Do not only test the view that exposed the bug. Test the owning state layer.
