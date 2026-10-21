#!/bin/bash
# Builds a downloadable Driftwall: a universal app (Apple silicon and Intel) in a drag-to-Applications
# disk image, so people can use Driftwall without cloning the repository or building it.
#
#   scripts/package_release.sh
#
# Output: dist/Driftwall-<version>.dmg, its SHA-256 checksum, and RELEASE_NOTES-<version>.md for the
# GitHub release page.
#
# By default the app is ad-hoc signed (free, no Apple Developer ID). It works, but macOS asks for
# approval the first time it's opened; the release notes explain how. If you ever get a Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="driftwall"   # created once with: xcrun notarytool store-credentials driftwall
# and the app and disk image are notarized and stapled, so they open without any warning.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(grep -m1 -oE '^## [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | cut -c4-)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
APP="$ROOT/build/Driftwall.app"
DIST="$ROOT/dist"
DMG="$DIST/Driftwall-$VERSION.dmg"

if [ -n "$NOTARY_PROFILE" ] && [ "$SIGN_IDENTITY" = "-" ]; then
  echo "NOTARY_PROFILE needs SIGN_IDENTITY: Apple only notarizes apps signed with a Developer ID." >&2
  exit 1
fi

echo "▸ Building Driftwall $VERSION (universal)"
UNIVERSAL=1 VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/build_app.sh" release

for binary in "$APP/Contents/MacOS/Driftwall" "$APP/Contents/Resources/Driftwall.saver/Contents/MacOS/DriftwallSaver"; do
  archs="$(lipo -archs "$binary")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "Not universal: $binary ($archs)" >&2; exit 1; }
done

notarize() {
  echo "▸ Notarizing $(basename "$1") (usually a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if [ -n "$NOTARY_PROFILE" ]; then
  ZIP="$DIST/Driftwall-notarize.zip"
  mkdir -p "$DIST"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

echo "▸ Creating $(basename "$DMG")"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Driftwall.app"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$DIST"
rm -f "$DMG"
hdiutil create -volname "Driftwall $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -quiet "$DMG"

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [ -n "$NOTARY_PROFILE" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

# Release notes for the GitHub release page: install steps first (most people never read the
# README), then this version's changelog entry.
NOTES="$DIST/RELEASE_NOTES-$VERSION.md"
{
  echo "## Install"
  echo
  echo "1. Download **$(basename "$DMG")** below."
  echo "2. Open it and drag **Driftwall** onto **Applications**."
  echo "3. Open Driftwall from Applications."
  echo
  echo "Runs on macOS 14 Sonoma or later, on Apple silicon and Intel Macs."
  echo
  if [ -n "$NOTARY_PROFILE" ]; then
    echo "Driftwall is notarized by Apple and opens without any warning."
  else
    echo "**The first time you open it, macOS asks you to approve it. This is expected:** Driftwall is free and"
    echo "isn't signed with a paid Apple Developer ID, so macOS can't check who made it. Approve it once:"
    echo
    echo "- **macOS 15 Sequoia and later:** click **Done** on *\"Driftwall\" Not Opened*, then go to"
    echo "  **System Settings › Privacy & Security**, click **Open Anyway** next to *\"Driftwall\" was blocked…*"
    echo "  and confirm with your password."
    echo "- **macOS 14 Sonoma:** right-click Driftwall in Applications › **Open** › **Open**."
    echo "- **Or in Terminal:** \`xattr -dr com.apple.quarantine /Applications/Driftwall.app\`"
  fi
  echo
  echo "SHA-256: \`$(cut -d' ' -f1 "$DMG.sha256")\`"
  echo
  echo "## What's new"
  echo
  # The changelog entry for this version, without its heading.
  awk -v v="## $VERSION" 'index($0, v) == 1 { on = 1; next } on && /^## / { exit } on' CHANGELOG.md
} > "$NOTES"
echo "✓ $DMG ($(du -h "$DMG" | cut -f1))"
echo "  Release notes: $NOTES"
echo "  SHA-256: $(cut -d' ' -f1 "$DMG.sha256")"
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "  Ad-hoc signed: macOS asks for approval the first time it's opened (README › Install)."
else
  echo "  Signed with $SIGN_IDENTITY$([ -n "$NOTARY_PROFILE" ] && echo ", notarized and stapled")."
fi
