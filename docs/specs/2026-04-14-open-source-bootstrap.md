# macos-dictkit Open Source Bootstrap Spec

## Goal

Turn the current experimental Swift package into a publishable open source repository with a consistent public name, a minimal tracked file set, and a clean git history starting point.

## Decisions

- Repository name: `macos-dictkit`
- Swift package name: `macos-dictkit`
- Core parser module: `DictKit`
- macOS system dictionary module: `DictKitSystemDictionary`
- CLI executable: `dictkit`

## Repository Scope

The repository should track only files required to build, test, understand, and use the project:

- `Package.swift`
- `Package.resolved`
- `Sources/**`
- `Tests/**`
- `README.md`
- `LICENSE`
- `docs/specs/**`
- `.gitignore`

The repository should ignore generated or local-only artifacts:

- SwiftPM build output
- compiled objects and dependency files
- local executable artifacts
- editor and system metadata
- internal planning documents under `docs/superpowers/`

## Documentation

The top-level README should describe:

- the purpose of the project
- module boundaries
- supported platform and Swift version
- CLI usage
- local development commands
- the API stability caveat around Apple's dictionary payloads

## Validation

The bootstrap is complete when:

- `swift test` passes after the rename
- the tracked file set excludes generated artifacts
- git is initialized with a single clean starting commit for the public repository
- `origin` points to `git@github.com:fengkx/macos-dictkit.git`
