# Contribute

This repository uses Swift Package Manager and `just` recipes for day-to-day development.

The main end-user product is `anki-mate`, with supporting internal tools and modules such as `dictkit` and `AnkiMateServer`.

## Quick Start

Use the standard repo workflows:

```bash
just build
just test
just run-app
```

Prefer `just` recipes over ad hoc `swift` commands unless you need lower-level control.

## Development Docs

- Project map: [docs/agents/project-map.md](docs/agents/project-map.md)
- Development workflows: [docs/agents/dev-workflows.md](docs/agents/dev-workflows.md)
- Testing guide: [docs/agents/testing.md](docs/agents/testing.md)
- UI and state sync notes: [docs/agents/ui-state.md](docs/agents/ui-state.md)
- Troubleshooting: [docs/agents/troubleshooting.md](docs/agents/troubleshooting.md)

## Contribution Guidelines

- Add or update focused tests for every bug fix or behavior change.
- For parser, dictionary, and speech work, use the CLI loop before debugging through the app.
- For app state changes, make the source of truth, propagation, and persistence path explicit.

## Release Docs

- Release process: [docs/release.md](docs/release.md)
