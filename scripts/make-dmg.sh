#!/bin/bash
# Builds a release lumac.app and packages it as a drag-to-install DMG.
#
# The DMG is the distribution format because the app is *self-signed*, not
# notarised: a zip of a quarantined app gives the user a bare "damaged" dialog,
# while a DMG at least gets them to a window where right-click → Open works.
# See the quarantine note printed at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh release

APP="build/lumac.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/lumac-$VERSION.dmg"
STAGE="build/dmg-stage"

# A fresh staging directory each time: hdiutil copies whatever it finds, and a
# leftover older build would silently ship inside the image.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The /Applications alias is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "lumac $VERSION" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov -quiet \
  "$DMG"
rm -rf "$STAGE"

echo
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
echo
echo "Release checklist:"
echo "  1. tag must match the app version, prefixed with v:  v$VERSION"
echo "     (UpdateChecker compares LumacVersion.number against the GitHub tag)"
echo "  2. release notes must tell first-time users how to get past Gatekeeper:"
echo "       xattr -dr com.apple.quarantine /Applications/lumac.app"
echo "     self-signed builds are not notarised, so macOS blocks the first open"
