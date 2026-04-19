#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ICON="${1:-$ROOT_DIR/Assets/AppIcon.png}"
OUTPUT_ICNS="${2:-$ROOT_DIR/.build/AppIcon.icns}"

if [[ ! -f "$SOURCE_ICON" ]]; then
    echo "Missing source icon: $SOURCE_ICON" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to build AppIcon.icns" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT_ICNS")"

python3 - "$SOURCE_ICON" "$OUTPUT_ICNS" <<'PY'
import sys

try:
    from PIL import Image
except ModuleNotFoundError as exc:
    raise SystemExit(
        "Pillow is required to build AppIcon.icns. Install it with: python3 -m pip install pillow"
    ) from exc

source_icon, output_icns = sys.argv[1], sys.argv[2]
image = Image.open(source_icon).convert("RGBA")
image.save(output_icns, format="ICNS")
PY

echo "Built icon: $OUTPUT_ICNS"
