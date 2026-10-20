#!/bin/bash
# Builds Driftwall.app from the Swift package.
#
#   scripts/build_app.sh [debug|release]      (default: release)
#
# Output: build/Driftwall.app (ad-hoc signed, for running on this Mac).
#
# Why a script: SwiftPM produces a bare executable, not an .app bundle. A bundle is required for the
# Info.plist, app icon, bundled resources, launch-at-login (SMAppService) and normal Dock/menu-bar
# behaviour, so this script assembles one around the SwiftPM-built binary.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/Driftwall.app"
GENERATED="$ROOT/Resources/Generated"
VERSION="1.0.0"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

cd "$ROOT"
source "$ROOT/scripts/sdk_env.sh"

echo "▸ Building ($CONFIG) with SDK: ${SDKROOT:-default}"
swift build -c "$CONFIG" --product Driftwall
swift build -c release --product SampleMediaGenerator
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
GEN_BIN="$(swift build -c release --show-bin-path)/SampleMediaGenerator"

echo "▸ Rendering original sample wallpapers (cached after the first run)"
"$GEN_BIN" "$GENERATED"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Samples"
cp "$BIN_DIR/Driftwall" "$APP/Contents/MacOS/Driftwall"
cp "$ROOT/Resources/Catalog.json" "$APP/Contents/Resources/"
cp "$GENERATED"/Samples/*.mov "$APP/Contents/Resources/Samples/"

ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$GENERATED/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$GENERATED/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Driftwall</string>
  <key>CFBundleIdentifier</key><string>local.driftwall.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Driftwall</string>
  <key>CFBundleDisplayName</key><string>Driftwall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.lifestyle</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>Personal use build. Included wallpapers are original procedurally generated works.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

SIZE="$(du -sh "$APP" | cut -f1)"
echo "✓ Built $APP ($SIZE)"
echo "  Launch with: open \"$APP\""
