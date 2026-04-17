#!/usr/bin/env bash
# Fix dynamic library references for the app bundle.
# Usage: fixup-dylibs.sh <llama-lib-dir> <frameworks-dir> <server-binary>
set -euo pipefail

LIB_DIR="$1"
FRAMEWORKS_DIR="$2"
SERVER_BIN="$3"

# Dylib families to embed. Copying all matching names keeps the
# soname chain intact (e.g. libllama.dylib -> libllama.0.dylib -> real file).
DYLIB_PATTERNS=(
    libllama*.dylib
    libllama-common*.dylib
    libggml*.dylib
    libmtmd*.dylib
)

echo "==> Copying and fixing dylibs..."

for pattern in "${DYLIB_PATTERNS[@]}"; do
    for src in "$LIB_DIR"/$pattern; do
        [ -e "$src" ] || continue
        cp -P "$src" "$FRAMEWORKS_DIR/"
    done
done

# Set each real dylib's own install name to @rpath/<basename>.
for target in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -e "$target" ] || continue
    [ -L "$target" ] && continue
    dylib="$(basename "$target")"
    install_name_tool -id "@rpath/$dylib" "$target"
done

# Normalize server references to bundled @rpath libs.
while IFS= read -r current; do
    [ -n "$current" ] || continue
    dep="$(basename "$current")"
    [ -e "$FRAMEWORKS_DIR/$dep" ] || continue
    if [ "$current" != "@rpath/$dep" ]; then
        install_name_tool -change "$current" "@rpath/$dep" "$SERVER_BIN"
    fi
done < <(otool -L "$SERVER_BIN" | awk 'NR>1 {print $1}' | rg 'lib[^/]+\.dylib$' || true)

# Normalize inter-dylib references for every bundled real dylib.
for target in "$FRAMEWORKS_DIR"/*.dylib; do
    [ -e "$target" ] || continue
    [ -L "$target" ] && continue
    while IFS= read -r current; do
        [ -n "$current" ] || continue
        dep="$(basename "$current")"
        [ -e "$FRAMEWORKS_DIR/$dep" ] || continue
        if [ "$current" != "@rpath/$dep" ]; then
            install_name_tool -change "$current" "@rpath/$dep" "$target"
        fi
    done < <(otool -L "$target" | awk 'NR>1 {print $1}' | rg 'lib[^/]+\.dylib$' || true)
done

# Add @rpath to server binary pointing to Frameworks dir
install_name_tool -add_rpath "@executable_path/../Frameworks" "$SERVER_BIN" 2>/dev/null || true

echo "==> dylib fixup complete"
echo "    Frameworks: $(ls "$FRAMEWORKS_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') dylibs"
