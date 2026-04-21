# macOS DictKit development commands

swiftpm_env := ""
swiftpm_flags := "--disable-sandbox --scratch-path .build"
llama_swiftpm_flags := "-Xcc -I./vendor/llama-install/include -Xlinker -L./vendor/llama-install/lib"
llama_header := "vendor/llama-install/include/llama.h"
llama_lib_dir := "vendor/llama-install/lib"
cert_name := "AnkiMateDev"
cert_dir := ".build/certs"
llm_e2e_lockfile := "ci/llm-e2e-model.lock.json"
llm_benchmark_matrix_file := "ci/llm-benchmark-matrix.json"
default_llm_e2e_model_id := "gemma-4-e2b-it-q6k"

# List available recipes
default:
    @just --list

# Prepare the local build directory.
prepare-swiftpm:
    @mkdir -p .build

# Fail fast when llama.cpp artifacts are not prepared yet.
assert-llama:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f "{{llama_header}}" ] || [ ! -d "{{llama_lib_dir}}" ]; then
        echo "Missing vendor/llama-install. Run 'just build-llama' first."
        exit 1
    fi

# ── Build ──────────────────────────────────────────────

# Build the main products that are available in a fresh checkout.
build: prepare-swiftpm
    #!/usr/bin/env bash
    set -euo pipefail
    {{swiftpm_env}} swift build {{swiftpm_flags}} --product dictkit
    {{swiftpm_env}} swift build {{swiftpm_flags}} --product anki-mate
    {{swiftpm_env}} swift build {{swiftpm_flags}} --target DictKitAnkiExport
    if [ -f "{{llama_header}}" ] && [ -d "{{llama_lib_dir}}" ]; then
        {{swiftpm_env}} swift build {{swiftpm_flags}} --product AnkiMateServer {{llama_swiftpm_flags}}
    else
        echo "Skipping AnkiMateServer: vendor/llama-install is missing. Run 'just build-llama' to enable it."
    fi

# Build CLI only
build-cli: prepare-swiftpm
    {{swiftpm_env}} swift build {{swiftpm_flags}} --product dictkit

# Build the macOS app
build-app: prepare-swiftpm
    {{swiftpm_env}} swift build {{swiftpm_flags}} --product anki-mate

# Build the Anki export library
build-anki: prepare-swiftpm
    {{swiftpm_env}} swift build {{swiftpm_flags}} --target DictKitAnkiExport

# Build the main products in release mode
build-release: prepare-swiftpm
    #!/usr/bin/env bash
    set -euo pipefail
    {{swiftpm_env}} swift build {{swiftpm_flags}} -c release --product dictkit
    {{swiftpm_env}} swift build {{swiftpm_flags}} -c release --product anki-mate
    {{swiftpm_env}} swift build {{swiftpm_flags}} -c release --target DictKitAnkiExport
    if [ -f "{{llama_header}}" ] && [ -d "{{llama_lib_dir}}" ]; then
        {{swiftpm_env}} swift build {{swiftpm_flags}} -c release --product AnkiMateServer {{llama_swiftpm_flags}}
    else
        echo "Skipping AnkiMateServer release build: vendor/llama-install is missing. Run 'just build-llama' to enable it."
    fi

# Build a distributable macOS release zip under .build/release-dist.
package-release version: prepare-swiftpm
    APP_VERSION="{{version}}" ./scripts/package-macos-release.sh

# ── LLM / Inference ──────────────────────────────────

# Build llama.cpp from vendored submodule
build-llama:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f vendor/llama.cpp/CMakeLists.txt ]; then
        echo "Initializing llama.cpp submodule..."
        git submodule update --init vendor/llama.cpp
    fi
    if command -v brew >/dev/null 2>&1 && brew --prefix openssl@3 >/dev/null 2>&1; then
        OPENSSL_ROOT_DIR="$(brew --prefix openssl@3)"
        export OPENSSL_ROOT_DIR
        export CMAKE_PREFIX_PATH="$OPENSSL_ROOT_DIR${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
        export PKG_CONFIG_PATH="$OPENSSL_ROOT_DIR/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        echo "Using OpenSSL from $OPENSSL_ROOT_DIR"
    fi
    ./scripts/patch-llama-openssl.sh
    ./scripts/build-llama.sh

# Build the inference server (requires build-llama first)
build-server: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift build {{swiftpm_flags}} --product AnkiMateServer {{llama_swiftpm_flags}}

# ── Test ───────────────────────────────────────────────

# SwiftPM currently builds AnkiMateServer during test builds, so llama artifacts are required.
test: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}}

# Run tests with verbose output
test-verbose: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --verbose

# Run a specific test by filter (e.g. just test-filter CLISmoke)
test-filter filter: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter '{{filter}}'

# Run only AnkiExport tests
test-anki: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter AnkiExportTests

# Run focused AI artifact contract tests across app and export layers
test-ai-contract: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter AIArtifacts

# Run only DictKit core tests
test-core: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter DictKitTests

# Run speech integration tests (requires DICTKIT_RUN_SPEECH_TESTS=1)
test-speech: prepare-swiftpm assert-llama
    DICTKIT_RUN_SPEECH_TESTS=1 {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter Speech

# Run focused LLM prompt/service tests without optional local-model E2E coverage.
test-llm: prepare-swiftpm assert-llama
    {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter 'LLMPromptTests|LLMServiceTests'

# Download the pinned model used by LLM end-to-end tests.
prepare-llm-e2e-model:
    ./scripts/prepare-llm-e2e-model.sh {{llm_e2e_lockfile}}

# Download the models used by the multi-model benchmark suite.
prepare-llm-benchmark-models:
    ./scripts/prepare-llm-benchmark-models.sh {{llm_benchmark_matrix_file}}

# Run optional LLM end-to-end tests with a downloaded local model.
# Optional env:
#   DICTKIT_LLM_E2E_MODEL_ID=<model-id>
test-llm-e2e: prepare-swiftpm assert-llama
    DICTKIT_RUN_LLM_E2E_TESTS=1 DICTKIT_LLM_E2E_MODEL_ID="${DICTKIT_LLM_E2E_MODEL_ID:-{{default_llm_e2e_model_id}}}" {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter LLMServiceE2ETests

# Run the multi-model LLM benchmark suite and emit markdown/json reports.
test-llm-benchmark: prepare-swiftpm assert-llama
    DICTKIT_RUN_LLM_E2E_TESTS=1 DICTKIT_LLM_E2E_MATRIX="${DICTKIT_LLM_E2E_MATRIX:-default}" DICTKIT_LLM_E2E_BENCHMARK_ROUNDS="${DICTKIT_LLM_E2E_BENCHMARK_ROUNDS:-1}" DICTKIT_LLM_E2E_REPORT_DIR="${DICTKIT_LLM_E2E_REPORT_DIR:-.build/llm-benchmark-report}" {{swiftpm_env}} swift test {{swiftpm_flags}} {{llama_swiftpm_flags}} --filter LLMModelBenchmarkE2ETests

# CI helper for the pinned LLM end-to-end path.
ci-llm-e2e: build-llama prepare-llm-e2e-model test-llm-e2e

# ── Run ────────────────────────────────────────────────

# Run the CLI with arguments (e.g. just run apple)
run *args: prepare-swiftpm
    {{swiftpm_env}} swift run {{swiftpm_flags}} dictkit {{args}}

# Lookup a word (e.g. just lookup apple)
lookup *words: prepare-swiftpm
    {{swiftpm_env}} swift run {{swiftpm_flags}} dictkit {{words}}

# Lookup a word as JSON
lookup-json *words: prepare-swiftpm
    {{swiftpm_env}} swift run {{swiftpm_flags}} dictkit --json {{words}}

# Speak a word and save to wav (e.g. just speak apple)
speak word: prepare-swiftpm
    {{swiftpm_env}} swift run {{swiftpm_flags}} dictkit speech --output ./{{word}}.wav {{word}}

# Run the macOS app (builds, signs, bundles and opens it)
run-app: prepare-swiftpm
    #!/usr/bin/env bash
    set -euo pipefail
    pkill -9 -f 'anki-mate\.app' 2>/dev/null || true
    pkill -9 -f 'anki-mate-server' 2>/dev/null || true
    sleep 0.5

    {{swiftpm_env}} swift build {{swiftpm_flags}} --product anki-mate

    has_llama=false
    if [ -f "{{llama_header}}" ] && [ -d "{{llama_lib_dir}}" ]; then
        echo "Building inference server..."
        {{swiftpm_env}} swift build {{swiftpm_flags}} --product AnkiMateServer {{llama_swiftpm_flags}}
        has_llama=true
    else
        echo "Skipping AnkiMateServer: vendor/llama-install is missing. Run 'just build-llama' to enable it."
    fi

    if security find-identity -v -p codesigning | grep -q '{{cert_name}}'; then
        codesign -s '{{cert_name}}' -f .build/debug/anki-mate
    fi

    app_bundle=".build/anki-mate.app"
    app_dir="$app_bundle/Contents/MacOS"
    app_resources_dir="$app_bundle/Contents/Resources"
    app_frameworks_dir="$app_bundle/Contents/Frameworks"

    rm -rf "$app_bundle"
    mkdir -p "$app_dir" "$app_resources_dir" "$app_frameworks_dir"
    cp .build/debug/anki-mate "$app_dir/"

    if [ "$has_llama" = true ]; then
        cp .build/debug/AnkiMateServer "$app_dir/anki-mate-server"
        ./scripts/fixup-dylibs.sh vendor/llama-install/lib "$app_frameworks_dir" "$app_dir/anki-mate-server"
    fi

    cp Assets/AppIcon.png "$app_resources_dir/"
    cat > "$app_bundle/Contents/Info.plist" << 'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleExecutable</key>
        <string>anki-mate</string>
        <key>CFBundleIdentifier</key>
        <string>dev.ankimate.app</string>
        <key>CFBundleName</key>
        <string>Anki Mate</string>
        <key>CFBundleDisplayName</key>
        <string>Anki Mate</string>
        <key>CFBundleIconFile</key>
        <string>AppIcon.png</string>
        <key>CFBundlePackageType</key>
        <string>APPL</string>
        <key>CFBundleShortVersionString</key>
        <string>0.1.0</string>
        <key>LSMinimumSystemVersion</key>
        <string>13.0</string>
        <key>NSHighResolutionCapable</key>
        <true/>
        <key>NSSpeechRecognitionUsageDescription</key>
        <string>Anki Mate uses speech synthesis for word pronunciation.</string>
    </dict>
    </plist>
    PLIST

    if security find-identity -v -p codesigning | grep -q '{{cert_name}}'; then
        codesign -s '{{cert_name}}' -f --deep "$app_bundle"
    fi

    open -n "$app_bundle"

# ── Code Signing ──────────────────────────────────────

# Check if the code signing certificate exists
cert-check:
    @security find-identity -v -p codesigning | grep -q '{{cert_name}}' \
        && echo "Certificate '{{cert_name}}' found" \
        || echo "Certificate '{{cert_name}}' not found. Run: just cert-create"

# Create a self-signed code signing certificate and trust it
cert-create:
    #!/usr/bin/env bash
    set -euo pipefail
    if security find-identity -v -p codesigning | grep -q '{{cert_name}}'; then
        echo "Certificate '{{cert_name}}' already exists"
        exit 0
    fi
    mkdir -p {{cert_dir}}
    echo "Generating self-signed code signing certificate '{{cert_name}}'..."
    cat > {{cert_dir}}/codesign.cnf << 'CONF'
    [req]
    distinguished_name = req_dn
    x509_extensions = codesign_ext
    prompt = no
    [req_dn]
    CN = {{cert_name}}
    [codesign_ext]
    keyUsage = critical, digitalSignature
    extendedKeyUsage = critical, codeSigning
    CONF
    openssl req -x509 -newkey rsa:2048 \
        -keyout {{cert_dir}}/key.pem -out {{cert_dir}}/cert.pem \
        -days 3650 -nodes -config {{cert_dir}}/codesign.cnf 2>/dev/null
    openssl pkcs12 -export -out {{cert_dir}}/cert.p12 \
        -inkey {{cert_dir}}/key.pem -in {{cert_dir}}/cert.pem \
        -passout pass:ankimate -legacy 2>/dev/null
    echo "Importing into login keychain..."
    security import {{cert_dir}}/cert.p12 -k ~/Library/Keychains/login.keychain-db \
        -P "ankimate" -T /usr/bin/codesign -A
    echo "Trusting certificate for code signing..."
    security add-trusted-cert -d -r trustRoot -p codeSign \
        -k ~/Library/Keychains/login.keychain-db {{cert_dir}}/cert.pem
    rm -f {{cert_dir}}/key.pem {{cert_dir}}/cert.pem {{cert_dir}}/cert.p12 {{cert_dir}}/codesign.cnf
    rmdir {{cert_dir}} 2>/dev/null || true
    echo "Certificate '{{cert_name}}' created and trusted"

# Remove the self-signed certificate
cert-remove:
    #!/usr/bin/env bash
    set -euo pipefail
    security delete-identity -c '{{cert_name}}' 2>/dev/null || true
    security remove-trusted-cert -c '{{cert_name}}' 2>/dev/null || true
    echo "Certificate '{{cert_name}}' removed"

# Sign the built app binary
sign: build-app
    codesign -s '{{cert_name}}' -f .build/debug/anki-mate
    @echo "Signed .build/debug/anki-mate"

# ── Maintenance ────────────────────────────────────────

# Clean build artifacts
clean: prepare-swiftpm
    {{swiftpm_env}} swift package {{swiftpm_flags}} clean

# Full clean including .build directory
clean-all:
    rm -rf .build

# Resolve dependencies
resolve: prepare-swiftpm
    {{swiftpm_env}} swift package {{swiftpm_flags}} resolve

# Update dependencies
update: prepare-swiftpm
    {{swiftpm_env}} swift package {{swiftpm_flags}} update

# Show dependency graph
deps: prepare-swiftpm
    {{swiftpm_env}} swift package {{swiftpm_flags}} show-dependencies --format tree

# ── CI ─────────────────────────────────────────────────

# CI pipeline: build the main products, then run tests with llama artifacts available.
ci: build test
