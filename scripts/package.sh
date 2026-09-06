#!/bin/bash
# Packages dist/Pipit.app as a zip and a dmg, with checksums.
#
# Usage: scripts/package.sh <version>
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(cat "$REPO_ROOT/VERSION")}"
APP="$REPO_ROOT/dist/Pipit.app"
OUT="$REPO_ROOT/dist"

test -d "$APP" || { echo "build the app first: scripts/bundle-app.sh release" >&2; exit 1; }

ZIP="$OUT/Pipit-$VERSION.zip"
DMG="$OUT/Pipit-$VERSION.dmg"
rm -f "$ZIP" "$DMG"

# ditto preserves the bundle's signature and symlinks; zip does not.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# create-dmg copies the contents of the source folder, so the app goes into a
# staging directory of its own. The Applications link comes from
# --app-drop-link.
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"

# create-dmg copies one background file, so a sibling background@2x.png is
# never carried into the image. A multi-representation TIFF is the way to give
# Finder both sizes in one file.
BACKGROUND="$(mktemp -d)/background.tiff"
tiffutil -cathidpicheck \
  "$REPO_ROOT/Assets/Pipit/DMG/background.png" \
  "$REPO_ROOT/Assets/Pipit/DMG/background@2x.png" \
  -out "$BACKGROUND" >/dev/null

# create-dmg lays the window out by driving Finder through AppleScript. On a
# runner with no GUI session that call can time out. create-dmg retries it and
# then exits non-zero, which fails the release. The fix is to give the step a
# logged-in GUI session, or to raise --applescript-sleep-duration. Do not
# reach for --skip-jenkins: it skips the AppleScript altogether and ships a
# disk image with no layout at all.
create-dmg \
  --volname "Pipit $VERSION" \
  --volicon "$REPO_ROOT/Assets/Pipit/AppIcons/Pipit.icns" \
  --background "$BACKGROUND" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "Pipit.app" 180 190 \
  --hide-extension "Pipit.app" \
  --app-drop-link 480 190 \
  --no-internet-enable \
  "$DMG" \
  "$STAGING"
rm -rf "$STAGING" "$(dirname "$BACKGROUND")"

( cd "$OUT" && shasum -a 256 "Pipit-$VERSION.zip" "Pipit-$VERSION.dmg" ) > "$OUT/Pipit-$VERSION.sha256"
cat "$OUT/Pipit-$VERSION.sha256"
