#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MATRIX_FILE="${1:-${DICTKIT_LLM_BENCHMARK_MATRIX_FILE:-$ROOT_DIR/ci/llm-benchmark-matrix.json}}"
REGISTRY_FILE="${DICTKIT_LLM_REGISTRY_FILE:-$ROOT_DIR/Sources/AnkiMateLLM/Resources/models-registry.json}"
MODELS_DIR="${ANKIMATE_MODELS_DIR:-$HOME/Library/Application Support/Anki Mate/models}"

if [ ! -f "$MATRIX_FILE" ]; then
    echo "error: benchmark matrix file not found: $MATRIX_FILE" >&2
    exit 1
fi

if [ ! -f "$REGISTRY_FILE" ]; then
    echo "error: model registry file not found: $REGISTRY_FILE" >&2
    exit 1
fi

mkdir -p "$MODELS_DIR"

file_size() {
    stat -f%z "$1"
}

fetch_model_field() {
    python3 - "$REGISTRY_FILE" "$MATRIX_FILE" <<'PY'
import json
import sys

registry_file, matrix_file = sys.argv[1], sys.argv[2]
registry = json.load(open(registry_file, "r", encoding="utf-8"))
matrix = json.load(open(matrix_file, "r", encoding="utf-8"))
registry_by_id = {item["id"]: item for item in registry}

for model in matrix["models"]:
    model_id = model["modelId"]
    if model_id not in registry_by_id:
        raise SystemExit(f"missing model in registry: {model_id}")
    resolved = registry_by_id[model_id]
    print("\t".join([
        resolved["id"],
        resolved["displayName"],
        resolved["fileName"],
        resolved["url"],
        str(resolved["sizeBytes"])
    ]))
PY
}

echo "Preparing benchmark models from: $MATRIX_FILE"

while IFS=$'\t' read -r model_id display_name file_name model_url size_bytes; do
    target_path="$MODELS_DIR/$file_name"
    partial_path="$target_path.part"

    if [ -f "$target_path" ]; then
        actual_size="$(file_size "$target_path")"
        if [ "$actual_size" = "$size_bytes" ]; then
            echo "Benchmark model already present: $model_id -> $target_path"
            continue
        fi

        echo "Removing invalid cached model for $model_id: expected $size_bytes, got $actual_size"
        rm -f "$target_path"
    fi

    echo "Preparing benchmark model:"
    echo "  id: $model_id"
    echo "  name: $display_name"
    echo "  path: $target_path"

    curl \
        --location \
        --fail \
        --show-error \
        --progress-bar \
        --retry 5 \
        --retry-delay 5 \
        --continue-at - \
        --output "$partial_path" \
        "$model_url"

    actual_size="$(file_size "$partial_path")"
    if [ "$actual_size" != "$size_bytes" ]; then
        echo "error: size mismatch for $model_id: expected $size_bytes, got $actual_size" >&2
        exit 1
    fi

    mv "$partial_path" "$target_path"
    echo "Benchmark model ready: $target_path"
done < <(fetch_model_field)
