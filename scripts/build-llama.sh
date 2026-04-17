#!/usr/bin/env bash
# Build llama.cpp dynamic libraries from the vendored submodule.
# Usage: ./scripts/build-llama.sh
#
# Prerequisites:
#   git submodule update --init vendor/llama.cpp
#   cmake (via Homebrew or Xcode)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LLAMA_SRC="$ROOT_DIR/vendor/llama.cpp"
LLAMA_BUILD="$ROOT_DIR/vendor/llama-build"
LLAMA_INSTALL="$ROOT_DIR/vendor/llama-install"

# ── Pre-flight checks ────────────────────────────────────

if [ ! -d "$LLAMA_SRC/CMakeLists.txt" ] && [ ! -f "$LLAMA_SRC/CMakeLists.txt" ]; then
    echo "error: vendor/llama.cpp not found."
    echo "       Run: git submodule update --init vendor/llama.cpp"
    exit 1
fi

if ! command -v cmake &>/dev/null; then
    echo "error: cmake is required but not found."
    echo "       Install via: brew install cmake"
    exit 1
fi

# ── Build ─────────────────────────────────────────────────

echo "==> Configuring llama.cpp (ARM64, Metal, shared libs)..."
cmake -S "$LLAMA_SRC" -B "$LLAMA_BUILD" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$LLAMA_INSTALL"

JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)"
echo "==> Building llama.cpp with $JOBS parallel jobs..."
cmake --build "$LLAMA_BUILD" --config Release -j"$JOBS"

echo "==> Installing to vendor/llama-install/..."
cmake --install "$LLAMA_BUILD"

# ── Summary ───────────────────────────────────────────────

echo ""
echo "llama.cpp build complete."
echo "  headers : $LLAMA_INSTALL/include/"
echo "  libs    : $LLAMA_INSTALL/lib/"
echo ""
echo "Installed dylibs:"
ls -1 "$LLAMA_INSTALL/lib/"*.dylib 2>/dev/null || echo "  (none found)"
