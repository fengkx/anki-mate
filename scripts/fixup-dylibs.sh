#!/usr/bin/env bash
# Fix dynamic library references for the app bundle.
# Usage: fixup-dylibs.sh <llama-lib-dir> <frameworks-dir> <server-binary>
set -euo pipefail

LIB_DIR="$1"
FRAMEWORKS_DIR="$2"
SERVER_BIN="$3"

# Dylibs to embed — order matters for inter-lib dependencies
DYLIBS=(libllama.dylib libggml.dylib libggml-base.dylib libggml-metal.dylib libggml-cpu.dylib)

echo "==> Copying and fixing dylibs..."

for dylib in "${DYLIBS[@]}"; do
    src="$LIB_DIR/$dylib"
    [ -f "$src" ] || continue

    dst="$FRAMEWORKS_DIR/$dylib"
    cp "$src" "$dst"

    # Set the dylib's own install name to @rpath
    install_name_tool -id "@rpath/$dylib" "$dst"

    # Fix the server binary's reference to this dylib
    current=$(otool -L "$SERVER_BIN" | grep "$dylib" | head -1 | awk '{print $1}' || true)
    if [ -n "$current" ] && [ "$current" != "@rpath/$dylib" ]; then
        install_name_tool -change "$current" "@rpath/$dylib" "$SERVER_BIN"
    fi
done

# Fix inter-dylib references (e.g. libllama depends on libggml)
for dylib in "${DYLIBS[@]}"; do
    target="$FRAMEWORKS_DIR/$dylib"
    [ -f "$target" ] || continue

    for dep in "${DYLIBS[@]}"; do
        [ "$dylib" = "$dep" ] && continue
        current=$(otool -L "$target" | grep "$dep" | head -1 | awk '{print $1}' || true)
        if [ -n "$current" ] && [ "$current" != "@rpath/$dep" ]; then
            install_name_tool -change "$current" "@rpath/$dep" "$target"
        fi
    done
done

# Add @rpath to server binary pointing to Frameworks dir
install_name_tool -add_rpath "@executable_path/../Frameworks" "$SERVER_BIN" 2>/dev/null || true

echo "==> dylib fixup complete"
echo "    Frameworks: $(ls "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') dylibs"
