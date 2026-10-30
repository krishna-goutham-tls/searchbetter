#!/bin/bash
# Builds build/mac-search.app with plain swiftc (Command Line Tools are enough) and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/mac-search.app"
CONTENTS="$APP/Contents"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -O -swift-version 5 -sdk "$SDK" -target arm64-apple-macos14.0 \
    -module-name MacSearch -framework AppKit -framework Carbon -framework CoreServices -framework PDFKit \
    -framework ImageIO -framework UniformTypeIdentifiers -lsqlite3 \
    -o "$CONTENTS/MacOS/mac-search" Sources/*.swift

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>mac-search</string>
    <key>CFBundleIdentifier</key><string>space.thelaunch.macsearch</string>
    <key>CFBundleName</key><string>mac-search</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>mac-search reads your Desktop so you can find files by name and by what they hold. Nothing leaves your Mac.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>mac-search reads Documents so you can find files by name and by what they hold. Nothing leaves your Mac.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>mac-search reads Downloads so you can find files by name and by what they hold. Nothing leaves your Mac.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier space.thelaunch.macsearch "$APP"
echo "built $APP"
