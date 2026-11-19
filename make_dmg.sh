#!/bin/bash
# Packs build/"Unique AV RF Scan Co-ord.app" into a drag-to-install disk image:
#   build/Unique-AV-RF-Scan-Co-ord-<version>.dmg
# Run ./build_app.sh first (or use: ./build_app.sh && ./make_dmg.sh).
set -euo pipefail
cd "$(dirname "$0")"

NAME="Unique AV RF Scan Co-ord"
APP="build/${NAME}.app"
[ -d "$APP" ] || { echo "✗ ${APP} not found – run ./build_app.sh first"; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Unique-AV-RF-Scan-Co-ord-${VERSION}.dmg"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"          # drag the app onto this shortcut to install
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"   # disk icon in Finder
fi

echo "▸ Creating ${DMG}…"
rm -f "$DMG"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null

# Mark the custom volume icon (best effort; SetFile ships with the Xcode tools).
if [ -f "$STAGE/.VolumeIcon.icns" ] && command -v SetFile >/dev/null 2>&1; then
  RW="${DMG%.dmg}-rw.dmg"
  hdiutil convert "$DMG" -format UDRW -o "$RW" -ov >/dev/null
  MNT=$(hdiutil attach "$RW" -nobrowse -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)
  SetFile -a C "$MNT" || true
  hdiutil detach "$MNT" -quiet || true
  hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -ov >/dev/null
  rm -f "$RW"
fi

codesign --force --sign - "$DMG" 2>/dev/null || true
echo "✓ Done: ${DMG} ($(du -h "$DMG" | cut -f1))"
