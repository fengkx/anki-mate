#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCKFILE="${1:-${DICTKIT_LLM_E2E_LOCKFILE:-$ROOT_DIR/ci/llm-e2e-model.lock.json}}"
MODELS_DIR="${ANKIMATE_MODELS_DIR:-$HOME/Library/Application Support/Anki Mate/models}"

if [ ! -f "$LOCKFILE" ]; then
    echo "error: lockfile not found: $LOCKFILE" >&2
    exit 1
fi

eval "$(
    python3 - "$LOCKFILE" <<'PY'
import json
import shlex
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)

mapping = {
    "modelId": "MODEL_ID",
    "displayName": "DISPLAY_NAME",
    "fileName": "FILE_NAME",
    "url": "MODEL_URL",
    "sizeBytes": "SIZE_BYTES",
    "sha256": "SHA256",
    "cacheVersion": "CACHE_VERSION",
}

for source_key, target_key in mapping.items():
    value = data.get(source_key, "")
    if value is None:
        value = ""
    print(f"{target_key}={shlex.quote(str(value))}")
PY
)"

mkdir -p "$MODELS_DIR"

TARGET_PATH="$MODELS_DIR/$FILE_NAME"
PARTIAL_PATH="$TARGET_PATH.part"

file_size() {
    stat -f%z "$1"
}

sha256_of() {
    shasum -a 256 "$1" | awk '{print $1}'
}

validate_file() {
    local path="$1"
    local actual_size
    actual_size="$(file_size "$path")"
    if [ "$actual_size" != "$SIZE_BYTES" ]; then
        echo "size mismatch for $path: expected $SIZE_BYTES, got $actual_size" >&2
        return 1
    fi

    if [ -n "$SHA256" ]; then
        local actual_sha
        actual_sha="$(sha256_of "$path")"
        if [ "$actual_sha" != "$SHA256" ]; then
            echo "sha256 mismatch for $path: expected $SHA256, got $actual_sha" >&2
            return 1
        fi
    fi

    return 0
}

if [ -f "$TARGET_PATH" ]; then
    if validate_file "$TARGET_PATH"; then
        echo "LLM E2E model already present: $TARGET_PATH"
        exit 0
    fi

    echo "Removing invalid cached model: $TARGET_PATH"
    rm -f "$TARGET_PATH"
fi

if [ -f "$PARTIAL_PATH" ]; then
    partial_size="$(file_size "$PARTIAL_PATH" || echo 0)"
    if [ "$partial_size" -gt "$SIZE_BYTES" ]; then
        echo "Removing oversized partial download: $PARTIAL_PATH"
        rm -f "$PARTIAL_PATH"
    fi
fi

echo "Preparing LLM E2E model:"
echo "  id: $MODEL_ID"
echo "  name: $DISPLAY_NAME"
echo "  path: $TARGET_PATH"
echo "  cache version: $CACHE_VERSION"

curl \
    --location \
    --fail \
    --show-error \
    --progress-bar \
    --retry 5 \
    --retry-delay 5 \
    --continue-at - \
    --output "$PARTIAL_PATH" \
    "$MODEL_URL"

validate_file "$PARTIAL_PATH"
mv "$PARTIAL_PATH" "$TARGET_PATH"

echo "LLM E2E model ready: $TARGET_PATH"
