#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$BUILD_DIR/release-dist}"
APP_VERSION="${APP_VERSION:?APP_VERSION is required}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-1}"
APP_NAME="${APP_NAME:-Anki Mate}"
APP_BUNDLE_NAME="${APP_NAME}.app"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-dev.ankimate.app}"
APP_MINIMUM_SYSTEM_VERSION="${APP_MINIMUM_SYSTEM_VERSION:-13.0}"
APP_ARCHIVE_BASENAME="${APP_ARCHIVE_BASENAME:-Anki-Mate-${APP_VERSION}-macos-arm64}"
APP_ICON_SOURCE="${APP_ICON_SOURCE:-$ROOT_DIR/Assets/AppIcon.png}"
APP_EXECUTABLE_PATH="$BUILD_DIR/$BUILD_CONFIGURATION/anki-mate"
SERVER_EXECUTABLE_PATH="$BUILD_DIR/$BUILD_CONFIGURATION/AnkiMateServer"
LLAMA_HEADER_PATH="${LLAMA_HEADER_PATH:-$ROOT_DIR/vendor/llama-install/include/llama.h}"
LLAMA_LIB_DIR="${LLAMA_LIB_DIR:-$ROOT_DIR/vendor/llama-install/lib}"

APP_BUNDLE_PATH="$DIST_DIR/$APP_BUNDLE_NAME"
APP_CONTENTS_DIR="$APP_BUNDLE_PATH/Contents"
APP_MACOS_DIR="$APP_CONTENTS_DIR/MacOS"
APP_RESOURCES_DIR="$APP_CONTENTS_DIR/Resources"
APP_FRAMEWORKS_DIR="$APP_CONTENTS_DIR/Frameworks"
ICON_OUTPUT_PATH="$DIST_DIR/AppIcon.icns"
NOTARIZATION_ZIP_PATH="$DIST_DIR/${APP_ARCHIVE_BASENAME}-notarization.zip"
FINAL_ZIP_PATH="$DIST_DIR/${APP_ARCHIVE_BASENAME}.zip"
CHECKSUM_PATH="$DIST_DIR/${APP_ARCHIVE_BASENAME}.sha256"
MANIFEST_PATH="$DIST_DIR/${APP_ARCHIVE_BASENAME}.manifest.json"
NOTARY_LOG_PATH="$DIST_DIR/${APP_ARCHIVE_BASENAME}.notary-log.json"

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE_PATH" "$FINAL_ZIP_PATH" "$NOTARIZATION_ZIP_PATH" "$CHECKSUM_PATH" "$MANIFEST_PATH" "$NOTARY_LOG_PATH"

build_release_binaries() {
    swift build --disable-sandbox --scratch-path "$BUILD_DIR" -c release --product anki-mate
    if [[ -f "$LLAMA_HEADER_PATH" && -d "$LLAMA_LIB_DIR" ]]; then
        swift build \
            --disable-sandbox \
            --scratch-path "$BUILD_DIR" \
            -c release \
            --product AnkiMateServer \
            -Xcc -I"$ROOT_DIR/vendor/llama-install/include" \
            -Xlinker -L"$ROOT_DIR/vendor/llama-install/lib"
    else
        echo "Skipping AnkiMateServer release build: vendor/llama-install is missing."
    fi
}

write_info_plist() {
    cat > "$APP_CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>anki-mate</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${APP_MINIMUM_SYSTEM_VERSION}</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>${APP_NAME} uses speech synthesis for word pronunciation.</string>
</dict>
</plist>
PLIST
}

sign_file() {
    local target="$1"
    local runtime_mode="${2:-false}"

    if [[ -z "${APPLE_DEVELOPER_IDENTITY:-}" ]]; then
        return 0
    fi

    local args=(
        --force
        --sign "$APPLE_DEVELOPER_IDENTITY"
        --timestamp
    )
    if [[ "$runtime_mode" == "true" ]]; then
        args+=(--options runtime)
    fi
    codesign "${args[@]}" "$target"
}

verify_bundle() {
    if [[ -z "${APPLE_DEVELOPER_IDENTITY:-}" ]]; then
        return 0
    fi

    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE_PATH"
    if [[ "${DID_NOTARIZE:-false}" == "true" ]]; then
        spctl -a -t exec -vv "$APP_BUNDLE_PATH"
    fi
}

create_release_bundle() {
    rm -rf "$APP_BUNDLE_PATH"
    mkdir -p "$APP_MACOS_DIR" "$APP_RESOURCES_DIR" "$APP_FRAMEWORKS_DIR"

    cp "$APP_EXECUTABLE_PATH" "$APP_MACOS_DIR/anki-mate"
    "$ROOT_DIR/scripts/build-app-icon.sh" "$APP_ICON_SOURCE" "$ICON_OUTPUT_PATH"
    cp "$ICON_OUTPUT_PATH" "$APP_RESOURCES_DIR/AppIcon.icns"

    if [[ -f "$SERVER_EXECUTABLE_PATH" && -f "$LLAMA_HEADER_PATH" && -d "$LLAMA_LIB_DIR" ]]; then
        cp "$SERVER_EXECUTABLE_PATH" "$APP_MACOS_DIR/anki-mate-server"
        "$ROOT_DIR/scripts/fixup-dylibs.sh" "$LLAMA_LIB_DIR" "$APP_FRAMEWORKS_DIR" "$APP_MACOS_DIR/anki-mate-server"
    fi

    write_info_plist
    xattr -cr "$APP_BUNDLE_PATH"
}

notarize_bundle() {
    if [[ -z "${APPLE_NOTARY_API_KEY_PATH:-}" || -z "${APPLE_NOTARY_KEY_ID:-}" || -z "${APPLE_NOTARY_ISSUER_ID:-}" ]]; then
        return 0
    fi

    ditto -c -k --keepParent "$APP_BUNDLE_PATH" "$NOTARIZATION_ZIP_PATH"
    local submission_json
    submission_json="$(
        xcrun notarytool submit "$NOTARIZATION_ZIP_PATH" \
            --key "$APPLE_NOTARY_API_KEY_PATH" \
            --key-id "$APPLE_NOTARY_KEY_ID" \
            --issuer "$APPLE_NOTARY_ISSUER_ID" \
            --wait \
            --output-format json
    )"
    printf '%s\n' "$submission_json" > "$DIST_DIR/${APP_ARCHIVE_BASENAME}.notary-submit.json"

    local submission_id
    submission_id="$(printf '%s\n' "$submission_json" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
    xcrun notarytool log "$submission_id" \
        --key "$APPLE_NOTARY_API_KEY_PATH" \
        --key-id "$APPLE_NOTARY_KEY_ID" \
        --issuer "$APPLE_NOTARY_ISSUER_ID" \
        "$NOTARY_LOG_PATH"

    xcrun stapler staple "$APP_BUNDLE_PATH"
    xcrun stapler validate "$APP_BUNDLE_PATH"
    DID_NOTARIZE=true
}

create_release_zip() {
    ditto -c -k --keepParent "$APP_BUNDLE_PATH" "$FINAL_ZIP_PATH"
    shasum -a 256 "$FINAL_ZIP_PATH" > "$CHECKSUM_PATH"
}

write_release_manifest() {
    /usr/bin/python3 - "$MANIFEST_PATH" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]
manifest = {
    "app_name": os.environ["APP_NAME"],
    "bundle_id": os.environ["APP_BUNDLE_ID"],
    "version": os.environ["APP_VERSION"],
    "build_number": os.environ["APP_BUILD_NUMBER"],
    "archive_name": os.path.basename(os.environ["FINAL_ZIP_PATH"]),
    "archive_sha256": os.environ["APP_ARCHIVE_SHA256"],
    "minimum_system_version": os.environ["APP_MINIMUM_SYSTEM_VERSION"],
    "signed": os.environ["APP_SIGNED"].lower() == "true",
    "notarized": os.environ["DID_NOTARIZE"].lower() == "true",
}

with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

if [[ "${SKIP_BUILD:-false}" != "true" ]]; then
    build_release_binaries
fi

if [[ ! -x "$APP_EXECUTABLE_PATH" ]]; then
    echo "Missing release binary: $APP_EXECUTABLE_PATH" >&2
    exit 1
fi

create_release_bundle

if [[ -f "$APP_MACOS_DIR/anki-mate-server" ]]; then
    while IFS= read -r dylib; do
        sign_file "$dylib"
    done < <(find "$APP_FRAMEWORKS_DIR" -type f -name '*.dylib' | sort)
    sign_file "$APP_MACOS_DIR/anki-mate-server" true
fi

sign_file "$APP_BUNDLE_PATH" true
DID_NOTARIZE=false
notarize_bundle
verify_bundle
create_release_zip
APP_ARCHIVE_SHA256="$(awk '{print $1}' "$CHECKSUM_PATH")"
export APP_ARCHIVE_SHA256
if [[ -n "${APPLE_DEVELOPER_IDENTITY:-}" ]]; then
    APP_SIGNED=true
else
    APP_SIGNED=false
fi
export APP_SIGNED
export FINAL_ZIP_PATH
write_release_manifest

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "app-bundle-path=$APP_BUNDLE_PATH"
        echo "zip-path=$FINAL_ZIP_PATH"
        echo "checksum-path=$CHECKSUM_PATH"
        echo "manifest-path=$MANIFEST_PATH"
        if [[ -f "$NOTARY_LOG_PATH" ]]; then
            echo "notary-log-path=$NOTARY_LOG_PATH"
        fi
    } >> "$GITHUB_OUTPUT"
fi

echo "Release artifacts written to $DIST_DIR"
