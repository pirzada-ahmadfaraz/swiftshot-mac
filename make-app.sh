#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Builds the release binary and (re)assembles CleanShotClone.app with the
# canonical Resources/Info.plist — the single source of truth for bundle keys
# and privacy usage descriptions (screen recording, microphone, camera).
#
# Signing: uses the stable "CleanShotClone Self-Signed" identity when present
# (create it once with ./setup-signing.sh) so TCC permission grants survive
# rebuilds; falls back to ad-hoc otherwise (TCC will re-prompt after rebuilds).

APP="CleanShotClone.app"

echo "==> Building (release)"
swift build -c release

echo "==> Assembling $APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/CleanShotClone" "$APP/Contents/MacOS/CleanShotClone"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

IDENTITY="CleanShotClone Self-Signed"
# Sign by SHA-1 hash, not by name — duplicate certs make name-based signing
# fail as "ambiguous", and pick the hash of a VALID (trusted) identity only.
HASH="$(security find-identity -v -p codesigning 2>/dev/null | grep "$IDENTITY" | head -1 | awk '{print $2}')"
if [ -n "$HASH" ]; then
    echo "==> Signing with '$IDENTITY' ($HASH)"
    codesign --force --sign "$HASH" "$APP"
else
    echo "==> Signing ad-hoc (tip: run ./setup-signing.sh once for a stable identity;"
    echo "    ad-hoc signatures change every rebuild, so TCC permissions won't stick)"
    codesign --force --sign - "$APP"
fi

echo "==> Verifying usage descriptions"
for key in NSMicrophoneUsageDescription NSCameraUsageDescription NSScreenCaptureUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist" >/dev/null
done

echo "Done → open $APP   (or: open $APP)"
