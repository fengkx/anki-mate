# Development Workflows

Use this file for day-to-day command loops.

## Ground Rules

- Prefer `just` over raw `swift` commands.
- The repo uses local SwiftPM cache paths under `.build/swiftpm-cache` to avoid sandbox and module-cache problems.
- `just build` is the default sanity check for a fresh checkout.

## Fastest Feedback Loops

### CLI as REPL

Use the CLI for ad-hoc debugging before touching the app:

```bash
just lookup apple
just lookup-json apple
just run --raw-html run
just speak apple
```

Use this loop when working on:

- parser behavior
- dictionary lookup selection
- speech request resolution
- fixture generation or regression triage

### App loop

```bash
just run-app
```

What it does:

1. builds `anki-mate`
2. builds `AnkiMateServer` if `vendor/llama-install` exists
3. bundles the app under `.build/anki-mate.app`
4. embeds inference dylibs when needed
5. opens a fresh app instance

Use this loop for SwiftUI, persistence, sync, and model-management work.

### LLM / inference loop

```bash
just build-llama
just build-server
just run-app
```

Use this when editing:

- `Sources/AnkiMateLLM`
- `Sources/AnkiMateServer`
- model download UI
- server launch or RPC behavior

## Canonical Build Commands

```bash
just build
just build-cli
just build-app
just build-anki
just build-release
just package-release 0.1.0
```

## Dependency And Maintenance Commands

```bash
just resolve
just update
just deps
just clean
just clean-all
```

## Code Signing Loop

Use only when local app signing is needed:

```bash
just cert-check
just cert-create
just sign
```

`run-app` already signs when a local `AnkiMateDev` certificate exists.

## When To Drop Below `just`

Use raw `swift build` or `swift test` only when you need:

- extra flags such as `--filter`
- direct control of include/link flags for llama
- to isolate a failing invocation that `just` wraps

If you drop below `just`, preserve the local SwiftPM cache flags used by `justfile`.
