#!/usr/bin/env bash
set -euo pipefail

decode_base64() {
    if base64 --help 2>/dev/null | grep -q -- '--decode'; then
        base64 --decode
    else
        base64 -D
    fi
}

: "${APPLE_DEVELOPER_ID_CERT_BASE64:?APPLE_DEVELOPER_ID_CERT_BASE64 is required}"
: "${APPLE_DEVELOPER_ID_CERT_PASSWORD:?APPLE_DEVELOPER_ID_CERT_PASSWORD is required}"

RUNNER_TEMP_DIR="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN_PATH="${APPLE_KEYCHAIN_PATH:-$RUNNER_TEMP_DIR/ankimate-signing.keychain-db}"
KEYCHAIN_PASSWORD="${APPLE_KEYCHAIN_PASSWORD:-$(uuidgen)$(uuidgen)}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CERT_PATH="$TMP_DIR/developer-id.p12"
printf '%s' "$APPLE_DEVELOPER_ID_CERT_BASE64" | decode_base64 > "$CERT_PATH"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

EXISTING_KEYCHAINS="$(
    security list-keychains -d user \
        | tr -d '"' \
        | sed 's/^[[:space:]]*//'
)"
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS
security default-keychain -s "$KEYCHAIN_PATH"

security import "$CERT_PATH" \
    -k "$KEYCHAIN_PATH" \
    -P "$APPLE_DEVELOPER_ID_CERT_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security \
    -T /usr/bin/productbuild

security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

DEVELOPER_IDENTITY="${APPLE_DEVELOPER_IDENTITY:-}"
if [[ -z "$DEVELOPER_IDENTITY" ]]; then
    DEVELOPER_IDENTITY="$(
        security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
            | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' \
            | head -n 1
    )"
fi

if [[ -z "$DEVELOPER_IDENTITY" ]]; then
    echo "Unable to locate a Developer ID Application identity in $KEYCHAIN_PATH" >&2
    exit 1
fi

if [[ -n "${GITHUB_ENV:-}" ]]; then
    {
        echo "APPLE_KEYCHAIN_PATH=$KEYCHAIN_PATH"
        echo "APPLE_KEYCHAIN_PASSWORD=$KEYCHAIN_PASSWORD"
        echo "APPLE_DEVELOPER_IDENTITY=$DEVELOPER_IDENTITY"
    } >> "$GITHUB_ENV"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "keychain-path=$KEYCHAIN_PATH"
        echo "identity=$DEVELOPER_IDENTITY"
    } >> "$GITHUB_OUTPUT"
fi

echo "Imported Developer ID certificate for identity: $DEVELOPER_IDENTITY"
