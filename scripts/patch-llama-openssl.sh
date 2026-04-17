#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_FILE="$ROOT_DIR/vendor/llama.cpp/vendor/cpp-httplib/CMakeLists.txt"

if [ ! -f "$TARGET_FILE" ]; then
    echo "skip: $TARGET_FILE not found"
    exit 0
fi

if rg -q 'find_package\(OpenSSL COMPONENTS SSL Crypto\)' "$TARGET_FILE"; then
    echo "OpenSSL component patch already applied."
    exit 0
fi

if ! rg -q 'find_package\(OpenSSL\)' "$TARGET_FILE"; then
    echo "skip: expected OpenSSL probe pattern not found in $TARGET_FILE"
    exit 0
fi

python3 - <<'PY'
from pathlib import Path

target = Path("vendor/llama.cpp/vendor/cpp-httplib/CMakeLists.txt")
src = target.read_text()
old = "elseif (LLAMA_OPENSSL)\n    find_package(OpenSSL)\n"
new = "elseif (LLAMA_OPENSSL)\n    find_package(OpenSSL COMPONENTS SSL Crypto)\n"
if old not in src:
    raise SystemExit("expected patch anchor not found")
target.write_text(src.replace(old, new, 1))
print("Applied OpenSSL component patch to cpp-httplib.")
PY
