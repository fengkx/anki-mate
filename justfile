# macOS DictKit development commands

# List available recipes
default:
    @just --list

# ── Build ──────────────────────────────────────────────

# Build all targets
build:
    swift build

# Build CLI only
build-cli:
    swift build --product dictkit

# Build the macOS app
build-app:
    swift build --product anki-mate

# Build the Anki export library
build-anki:
    swift build --target DictKitAnkiExport

# Build in release mode
build-release:
    swift build -c release

# ── Test ───────────────────────────────────────────────

# Run all tests
test:
    swift test

# Run tests with verbose output
test-verbose:
    swift test --verbose

# Run a specific test by filter (e.g. just test-filter CLISmoke)
test-filter filter:
    swift test --filter '{{filter}}'

# Run only AnkiExport tests
test-anki:
    swift test --filter AnkiExportTests

# Run only DictKit core tests (excludes Anki tests)
test-core:
    swift test --filter DictKitTests

# Run speech integration tests (requires DICTKIT_RUN_SPEECH_TESTS=1)
test-speech:
    DICTKIT_RUN_SPEECH_TESTS=1 swift test --filter Speech

# ── Run ────────────────────────────────────────────────

# Run the CLI with arguments (e.g. just run apple)
run *args:
    swift run dictkit {{args}}

# Lookup a word (e.g. just lookup apple)
lookup *words:
    swift run dictkit {{words}}

# Lookup a word as JSON
lookup-json *words:
    swift run dictkit --json {{words}}

# Speak a word and save to wav (e.g. just speak apple)
speak word:
    swift run dictkit speech --output ./{{word}}.wav {{word}}

# Run the macOS app (builds .app bundle and opens it)
run-app:
    #!/usr/bin/env bash
    set -euo pipefail
    # Kill any existing instance so macOS doesn't reuse a stale cached process
    pkill -9 -f 'anki-mate\.app' 2>/dev/null || true
    sleep 0.5
    swift build --product anki-mate
    ./scripts/build-app-icon.sh .build
    APP_BUNDLE=".build/anki-mate.app"
    APP_DIR="$APP_BUNDLE/Contents/MacOS"
    APP_RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
    # Remove old bundle to avoid any caching issues
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_DIR"
    mkdir -p "$APP_RESOURCES_DIR"
    cp .build/debug/anki-mate "$APP_DIR/"
    cp .build/AppIcon.icns "$APP_RESOURCES_DIR/"
    cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>anki-mate</string>
        <key>CFBundleIdentifier</key>
        <string>dev.dictkit.app</string>
        <key>CFBundleName</key>
        <string>anki-mate</string>
        <key>CFBundleDisplayName</key>
        <string>anki-mate</string>
        <key>CFBundleIconFile</key>
        <string>AppIcon</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>0.1.0</string>
        <key>LSMinimumSystemVersion</key>
        <string>13.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>NSSpeechRecognitionUsageDescription</key>
        <string>DictKit uses speech synthesis for word pronunciation.</string>
    </dict>
    </plist>
    PLIST
    open -n "$APP_BUNDLE"

# ── Maintenance ────────────────────────────────────────

# Clean build artifacts
clean:
    swift package clean

# Full clean including .build directory
clean-all:
    rm -rf .build

# Resolve dependencies
resolve:
    swift package resolve

# Update dependencies
update:
    swift package update

# Show dependency graph
deps:
    swift package show-dependencies --format tree

# ── CI ─────────────────────────────────────────────────

# CI pipeline: build all + run all tests
ci: build test
