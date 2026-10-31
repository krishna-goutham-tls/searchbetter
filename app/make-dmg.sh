#!/bin/bash
# Builds the app and packs it into a disk image with a link to Applications.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build.noindex/SearchBetter.app/Contents/Info.plist)"
OUT="build.noindex/SearchBetter-$VERSION.dmg"
STAGE="$(mktemp -d)"
ditto build.noindex/SearchBetter.app "$STAGE/SearchBetter.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -quiet -volname SearchBetter -srcfolder "$STAGE" -fs HFS+ -format UDZO "$OUT"
rm -rf "$STAGE"
ls -lh "$OUT"
