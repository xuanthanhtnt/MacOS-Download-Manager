#!/bin/bash
# Builds MacOS Download Manager.app (universal: Apple Silicon + Intel) and packages it as a .dmg.
#
#   ./scripts/build_app.sh            # version from VERSION env or 1.0.0
#   VERSION=1.2.0 ./scripts/build_app.sh
#
# Requires macOS with Xcode (or the Command Line Tools) installed.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
ARCHS="${ARCHS:-arm64 x86_64}"
OUT="$ROOT/build"
APP="$OUT/MacOS Download Manager.app"
DMG="$OUT/MacOS-Download-Manager-$VERSION.dmg"

echo "==> Building MacOS Download Manager $VERSION ($BUILD_NUMBER) for: $ARCHS"
ARCH_FLAGS=()
for a in $ARCHS; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}"
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/MacOSDownloadManager"
[ -f "$BIN" ] || { echo "Binary not found at $BIN"; exit 1; }
lipo -info "$BIN" || true

echo "==> Assembling app bundle"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MacOSDownloadManager"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
plutil -lint Resources/vi.lproj/Localizable.strings
cp -R Resources/en.lproj Resources/vi.lproj "$APP/Contents/Resources/"

./scripts/sync_extension.sh >/dev/null
mkdir -p "$APP/Contents/Resources/BrowserExtension"
cp -R BrowserExtension/chrome BrowserExtension/firefox "$APP/Contents/Resources/BrowserExtension/"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"

echo "==> Creating DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/DMG-README.txt" "$STAGE/Đọc trước khi cài - Read me.txt"
cp -R BrowserExtension/chrome "$STAGE/Browser Extension (Chrome, Edge, Brave)"
cp -R BrowserExtension/firefox "$STAGE/Browser Extension (Firefox)"
hdiutil create -volname "MacOS Download Manager $VERSION" -srcfolder "$STAGE" -ov -fs HFS+ -format UDZO "$DMG"
rm -rf "$STAGE"
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG"
