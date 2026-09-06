#!/bin/bash
# Assembles Pipit.app from the SwiftPM products.
#
# This is the route CI and the release workflow take, so it needs no Xcode
# project and no xcodebuild. App/Info.plist and App/Pipit.entitlements are the
# same two files Pipit.xcodeproj builds against. Signing is ad-hoc by default,
# which is enough to hold TCC grants for one build. Set PIPIT_SIGN_IDENTITY to
# a Developer ID Application identity for a distributable build.
#
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"

CONFIG="${1:-release}"
VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "0.1.0")"
BUILD_NUMBER="${PIPIT_BUILD_NUMBER:-1}"
# Read from the plist so the signing identifier and the bundle cannot drift.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$REPO_ROOT/App/Info.plist")"
APP_DIR="$REPO_ROOT/dist/Pipit.app"
BIN_DIR="$REPO_ROOT/.build/$CONFIG"

cd "$REPO_ROOT"
echo "==> building ($CONFIG)"
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product Pipit
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product pipit-nativehost

echo "==> building the browser extension"
"$REPO_ROOT/extension/build.sh" >/dev/null

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/Pipit" "$APP_DIR/Contents/MacOS/Pipit"
# The native messaging host sits next to the app executable so the installer can
# copy it to a stable absolute path outside any TCC-protected directory.
cp "$BIN_DIR/pipit-nativehost" "$APP_DIR/Contents/MacOS/pipit-nativehost"
cp -R "$REPO_ROOT/extension/dist" "$APP_DIR/Contents/Resources/extension"
# The signed add-on, when scripts/sign-extension.sh has produced one. Without it
# the app falls back to walking the user through about:debugging, which loads the
# extension until Firefox quits.
if [ -f "$REPO_ROOT/extension/signed/pipit-sensor.xpi" ]; then
    cp "$REPO_ROOT/extension/signed/pipit-sensor.xpi" \
        "$APP_DIR/Contents/Resources/extension/pipit-sensor.xpi"
    echo "==> bundled the signed Firefox add-on"
fi
cp "$REPO_ROOT/Assets/Pipit/AppIcons/Pipit.icns" "$APP_DIR/Contents/Resources/Pipit.icns"
for state in idle recording paused warning; do
    cp "$REPO_ROOT/Assets/Pipit/MenuBar/pipit-$state.png" "$APP_DIR/Contents/Resources/"
    cp "$REPO_ROOT/Assets/Pipit/MenuBar/pipit-$state@2x.png" "$APP_DIR/Contents/Resources/"
done

# The version keys are the only two the build stamps. Everything else in the
# bundle plist is what App/Info.plist says.
cp "$REPO_ROOT/App/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"

# The identity, in order: the one named in the environment, the local
# development certificate `scripts/make-signing-identity.sh` creates, then
# ad-hoc. TCC pins its grants to the signature's designated requirement, and an
# ad-hoc signature has none that survives a rebuild, so every ad-hoc install
# drops Microphone, Accessibility and Screen & System Audio Recording. A
# certificate, even a self-signed one, keeps them.
IDENTITY="${PIPIT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Pipit Development"'; then
    IDENTITY="Pipit Development"
fi
IDENTITY="${IDENTITY:--}"
# A secure timestamp is mandatory for notarization. Ad-hoc and self-signed
# signatures cannot have one.
case "$IDENTITY" in
    -)
        TIMESTAMP=(--timestamp=none)
        echo "==> signing ad-hoc"
        ;;
    "Developer ID"*)
        TIMESTAMP=(--timestamp)
        echo "==> signing with a Developer ID identity"
        ;;
    *)
        TIMESTAMP=(--timestamp=none)
        echo "==> signing with the local identity \"$IDENTITY\""
        ;;
esac
# A stable identifier is what lets the app recognise its own relay when the relay
# connects to the sensor socket.
codesign --force --sign "$IDENTITY" \
    --identifier "com.pipit.nativehost" \
    --options runtime \
    "${TIMESTAMP[@]}" \
    "$APP_DIR/Contents/MacOS/pipit-nativehost"
codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$REPO_ROOT/App/Pipit.entitlements" \
    "${TIMESTAMP[@]}" \
    "$APP_DIR"

codesign --verify --deep --strict --verbose=1 "$APP_DIR" 2>&1 | sed 's/^/    /'
echo "==> built $APP_DIR"
if [ "$IDENTITY" = "-" ]; then
    cat <<'NOTE'

    Signed ad-hoc. TCC pins its grants to the code hash, so every rebuild
    invalidates Microphone, Accessibility and Screen Recording and they have to
    be granted again. A Developer ID signature keeps a stable designated
    requirement and does not have this problem.
NOTE
fi
