#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="CleanShotClone"
BUILD_DIR="$PROJECT_DIR/.build"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
CONFIG="${CONFIG:-release}"

cd "$PROJECT_DIR"

echo "==> Building Swift package ($CONFIG)"
swift build -c "$CONFIG"

BIN_PATH="$BUILD_DIR/$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"

if [[ ! -f "$BIN_PATH" ]]; then
    echo "Build failed — binary not found at $BIN_PATH"
    exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$PROJECT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Sign with our stable self-signed identity so macOS TCC (Screen Recording
# permission) remembers the app across rebuilds. The cert is "untrusted" for
# Gatekeeper purposes, but codesign signs with it fine by its SHA-1 hash, and
# the resulting signature/designated-requirement is stable build-to-build.
IDENTITY_NAME="CleanShotClone Self-Signed"
IDENTITY_HASH="$(security find-identity -p codesigning 2>/dev/null | awk -v n="$IDENTITY_NAME" '$0 ~ n {print $2; exit}')"

if [[ -n "${IDENTITY_HASH:-}" ]]; then
    echo "==> Signing with stable identity ($IDENTITY_NAME / $IDENTITY_HASH)"
    codesign --force --deep --sign "$IDENTITY_HASH" "$APP_BUNDLE"
else
    echo "==> WARNING: stable identity not found — run ./setup-signing.sh once."
    echo "    Falling back to ad-hoc signing (TCC permission will reset each build)."
    codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Built: $APP_BUNDLE"
echo "Run with: open '$APP_BUNDLE'"
