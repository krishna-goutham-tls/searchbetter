#!/bin/bash
# Builds build.noindex/SearchBetter.app with plain swiftc (Command Line Tools are enough) and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="build.noindex/SearchBetter.app"
CONTENTS="$APP/Contents"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -O -swift-version 5 -sdk "$SDK" -target arm64-apple-macos14.0 \
    -module-name MacSearch -framework AppKit -framework Carbon -framework CoreServices -framework PDFKit \
    -framework ImageIO -framework UniformTypeIdentifiers -framework Vision -framework IOKit -lsqlite3 \
    -o "$CONTENTS/MacOS/SearchBetter" Sources/*.swift

# App icon, when Resources/AppIcon.png (1024 x 1024) exists.
if [ -f Resources/AppIcon.png ]; then
    SET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$SET"
    for s in 16 32 128 256 512; do
        sips -z $s $s Resources/AppIcon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
        d=$((s * 2))
        sips -z $d $d Resources/AppIcon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$SET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleExecutable</key><string>SearchBetter</string>
    <key>CFBundleIdentifier</key><string>space.thelaunch.macsearch</string>
    <key>CFBundleName</key><string>SearchBetter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSDesktopFolderUsageDescription</key><string>SearchBetter reads your Desktop so you can find files by name and by what they hold. Nothing leaves your Mac.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>SearchBetter reads Documents so you can find files by name and by what they hold. Nothing leaves your Mac.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>SearchBetter reads Downloads so you can find files by name and by what they hold. Nothing leaves your Mac.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --identifier space.thelaunch.macsearch "$APP"
echo "built $APP"
