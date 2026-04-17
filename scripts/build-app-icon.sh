#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/Assets/AppIcon.png"
BUILD_DIR="${1:-$ROOT_DIR/.build}"
OUTPUT_ICNS="$BUILD_DIR/AppIcon.icns"

if [[ ! -f "$SOURCE_ICON" ]]; then
    echo "Missing source icon: $SOURCE_ICON" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
rm -f "$OUTPUT_ICNS"

xattr -c "$SOURCE_ICON" 2>/dev/null || true

python3 - "$SOURCE_ICON" "$OUTPUT_ICNS" <<'PY'
import sys
from PIL import Image

source_icon, output_icns = sys.argv[1], sys.argv[2]
image = Image.open(source_icon).convert("RGBA")
image.save(output_icns, format="ICNS")
PY
