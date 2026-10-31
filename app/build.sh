#!/bin/bash
# Builds build.noindex/SearchBetter.app with plain swiftc (Command Line Tools are enough) and signs it ad hoc.
set -euo pipefail
cd "$(dirname "$0")"

APP="build.noindex/SearchBetter.app"
CONTENTS="$APP/Contents"
SDK="$(xcrun --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers"

swiftc -O -swift-version 5 -sdk "$SDK" -target arm64-apple-macos14.0 \
    -module-name MacSearch -framework AppKit -framework Carbon -framework CoreServices -framework PDFKit \
    -framework ImageIO -framework CryptoKit -framework UniformTypeIdentifiers -framework Vision -framework IOKit -lsqlite3 \
    -o "$CONTENTS/MacOS/SearchBetter" Sources/*.swift

# llama-server from the official llama.cpp release. It runs on macOS 13.3 and later and needs no Homebrew.
# The Homebrew build needs the same macOS as the Mac that built it, so it cannot ship.
LLAMA=b12020
LLAMA_SHA=b630ebd5da34b02e86f7294dd5743aba842a0a02cb023130debd64599721c541
VENDOR="build.noindex/vendor/llama-$LLAMA"
if [ ! -x "$VENDOR/llama-server" ]; then
    mkdir -p "$VENDOR"
    TGZ="$(mktemp)"
    curl -fsSL "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA/llama-$LLAMA-bin-macos-arm64.tar.gz" -o "$TGZ"
    echo "$LLAMA_SHA  $TGZ" | shasum -a 256 -c - >/dev/null
    tar -xzf "$TGZ" -C "$VENDOR" --strip-components 1
    rm -f "$TGZ"
fi
cp "$VENDOR/llama-server" "$CONTENTS/Helpers/"
for lib in llama-server-impl llama-common.0 mtmd.0 llama.0 ggml.0 ggml-base.0 ggml-cpu.0 ggml-blas.0 ggml-metal.0 ggml-rpc.0; do
    cp -L "$VENDOR/lib$lib.dylib" "$CONTENTS/Helpers/"
done
mkdir -p "$CONTENTS/Resources/licenses"
cp Resources/licenses/* "$CONTENTS/Resources/licenses/"
cp "$VENDOR/LICENSE" "$CONTENTS/Resources/licenses/llama.cpp-LICENSE.txt"

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

# Inside out: the helper files first, then the app that seals them.
codesign --force --sign - "$CONTENTS"/Helpers/*
codesign --force --sign - --identifier space.thelaunch.macsearch "$APP"
echo "built $APP"
