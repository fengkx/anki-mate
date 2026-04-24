# Project Guide

This file is the entry point for repository-specific guidance.

Keep this file short. Load the linked docs progressively based on the task instead of pulling everything into context.

## Quick Orientation

- Package manager: SwiftPM
- Primary command surface: `justfile`
- Main products:
  - `dictkit`: CLI for parser and dictionary inspection
  - `anki-mate`: macOS app
  - `AnkiMateServer`: local inference server backed by vendored `llama.cpp`
- Primary source roots:
  - `Sources/DictKit`: parsing and core models
  - `Sources/DictKitSystemDictionary`: macOS dictionary and speech integration
  - `Sources/DictKitApp`: app UI, persistence, sync, view models
  - `Sources/AnkiMateLLM`: model registry, downloads, RPC client, server lifecycle
  - `Sources/AnkiMateServer`: inference server
  - `Tests/DictKitTests`, `Tests/DictKitAppTests`, `Tests/AnkiExportTests`

## Quick Commands

- List commands: `just --list`
- Build core products: `just build`
- Run CLI inspection loop: `just lookup apple`, `just lookup-json apple`, `just run --json apple`
- Run app: `just run-app`
- Build local llama runtime: `just build-llama`
- Run full tests: `just test`
- Run focused tests: `just test-filter WordListViewModelTests`

## REPL Policy

This repository does not have a dedicated REPL shell. The practical REPL is the CLI:

- use `dictkit` for parser and dictionary inspection
- prefer `just lookup` / `just lookup-json` for fast ad-hoc checks
- use `just speak` for pronunciation pipelines

If the task is parser-, dictionary-, or speech-related, start with the CLI before opening the app.

## Progressive Disclosure

Open only the docs needed for the task:

- Specs directory map: [docs/specs/README.md](/Users/fengkx/me/code/macos-dictkit/docs/specs/README.md)
- Superpowers spec drafts: [docs/superpowers/specs/README.md](/Users/fengkx/me/code/macos-dictkit/docs/superpowers/specs/README.md)
- Project map and where to look: [docs/agents/project-map.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/project-map.md)
- Development workflows and command loops: [docs/agents/dev-workflows.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/dev-workflows.md)
- Testing strategy and test selection: [docs/agents/testing.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/testing.md)
- UI/state synchronization SOP: [docs/agents/ui-state.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/ui-state.md)
- Common failures and troubleshooting: [docs/agents/troubleshooting.md](/Users/fengkx/me/code/macos-dictkit/docs/agents/troubleshooting.md)

## Routing Heuristics

- Parser or CLI bug: open `project-map.md` and `testing.md`
- App UI, sync, persistence, or state bug: open `project-map.md`, `ui-state.md`, and `testing.md`
- Model download or inference bug: open `dev-workflows.md`, `testing.md`, and `troubleshooting.md`
- Build, signing, or launch problem: open `dev-workflows.md` and `troubleshooting.md`

## Rules Worth Repeating

1. Prefer `just` recipes over raw `swift` or ad hoc shell commands unless the task requires lower-level control.
2. Treat CLI checks as the first validation loop for parser and dictionary behavior.
3. For app state changes, make source of truth, propagation, and persistence explicit.
4. Add or update focused tests for every bug fix; do not rely on manual app verification alone.
5. When building chat-completion requests for local LLMs, emit at most one `system` message and keep it as the first message. Do not insert `system` messages into later history turns. If multiple system-level instructions exist, merge them before sending the request.
