#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# Builds SwiftShot.app (release, icon, signed) and packages a distributable
# SwiftShot.dmg ready to attach to a GitHub Release / host on the website.
#
# Signing: uses the stable "SwiftShot Self-Signed" / "CleanShotClone Self-Signed"
# identity if present (./setup-signing.sh) so a downloader's Screen-Recording grant
# PERSISTS across version updates; falls back to ad-hoc otherwise. Either way the
# app is NOT Apple-notarized, so first launch needs a one-time "Open Anyway".

APP="SwiftShot.app"
DMG="SwiftShot.dmg"
VOL="SwiftShot"
EXE="CleanShotClone"   # SPM product / binary name (matches CFBundleExecutable)

echo "==> Building (release)"
swift build -c release

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXE" "$APP/Contents/MacOS/$EXE"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing"
HASH="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -E "SwiftShot Self-Signed|CleanShotClone Self-Signed" | head -1 | awk '{print $2}')"
if [ -n "$HASH" ]; then
  codesign --force --sign "$HASH" "$APP"
  echo "   signed with stable identity $HASH (TCC grants persist across updates)"
else
  codesign --force --sign - "$APP"
  echo "   signed ad-hoc (tip: ./setup-signing.sh once for a stable identity)"
fi

echo "==> Packaging $DMG"
rm -f "$DMG"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "Done → $DMG ($(du -h "$DMG" | cut -f1))"
echo "Attach this to a GitHub Release or host it on swiftshot.online."
