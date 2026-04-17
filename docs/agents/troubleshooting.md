# Troubleshooting

Use this file for common local failures before diving into code.

## `just test` fails with missing `vendor/llama-install`

Cause:

- test builds currently require llama headers and dylibs because `AnkiMateServer` is in the graph

Fix:

```bash
just build-llama
just test
```

Check:

- `vendor/llama-install/include/llama.h`
- `vendor/llama-install/lib`

## `just run-app` builds app but model features do not work

Cause:

- app can launch without llama artifacts, but inference server is skipped

Fix:

```bash
just build-llama
just run-app
```

## UI changed in storage but did not refresh on screen

Suspect:

- store write happened outside the active view model
- parent view model is not forwarding child `ObservableObject` changes
- view directly mutated durable fields without persisting

Action:

- read [ui-state.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/ui-state.md)
- inspect `WordListViewModel`, `SyncEngine`, and the owning service
- add a focused regression test in `Tests/DictKitAppTests`

## Model download progress looks stale or inconsistent

Suspect:

- nested mutation inside `@Published downloads`
- status forwarding is throttled or split across too many layers

Action:

- inspect `ModelDownloadManager` and `LLMService`
- prefer full-value reassignment for published container entries
- add tests around status forwarding

## App launch/signing issues

Checks:

```bash
just cert-check
just cert-create
```

Notes:

- `run-app` only signs when `AnkiMateDev` exists
- local launch issues are often signing or dylib embedding issues rather than SwiftUI bugs

## `cmake` or llama build fails

Checks:

- `vendor/llama.cpp` submodule exists
- `cmake` is installed
- build script is `scripts/build-llama.sh`

Typical recovery:

```bash
git submodule update --init vendor/llama.cpp
just build-llama
```

## CLI is correct but app is wrong

Interpretation:

- parser and dictionary layers are probably fine
- bug is likely in app persistence, state ownership, view model propagation, or view binding

Start with:

- `Sources/DictKitApp/ViewModels/WordListViewModel.swift`
- `Sources/DictKitApp/Persistence/WordListStore.swift`
- `Sources/DictKitApp/Sync/SyncEngine.swift`

## App is correct after relaunch, but wrong immediately after an action

Interpretation:

- persistence may already be correct
- immediate UI propagation is likely broken

Start with:

- reload/merge hooks after store writes
- child-object subscriptions in the owning view model
- async status forwarding from services to the view model
