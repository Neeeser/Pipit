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
# scripts/app-version.sh owns the rule for all three values, so the run script
# phase in project.yml stamps what this script stamps. Set PIPIT_RELEASE=1 for
# the plain release version; anything else builds as <VERSION>-dev.<short sha>.
{ read -r SHORT_VERSION; read -r BUILD_NUMBER; read -r GIT_COMMIT; } < <("$REPO_ROOT/scripts/app-version.sh")
# Read from the plist so the signing identifier and the bundle cannot drift.
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$REPO_ROOT/App/Info.plist")"
UPDATE_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$REPO_ROOT/App/Info.plist" 2>/dev/null || true)"
if [ -z "$UPDATE_KEY" ] || [ "$UPDATE_KEY" = "REPLACE_WITH_PUBLIC_KEY" ]; then
    echo "==> warning: App/Info.plist carries the placeholder SUPublicEDKey, so this build cannot install an update. Fine locally, not for a release."
fi
APP_DIR="$REPO_ROOT/dist/Pipit.app"
BIN_DIR="$REPO_ROOT/.build/$CONFIG"

cd "$REPO_ROOT"
echo "==> building ($CONFIG)"
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product Pipit
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product pipit-nativehost
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product pipit-cli
swift build --configuration "$CONFIG" "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" --product pipit-safari-extension

echo "==> building the browser extension"
"$REPO_ROOT/extension/build.sh" >/dev/null

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/Pipit" "$APP_DIR/Contents/MacOS/Pipit"
# The native messaging host sits next to the app executable so the installer can
# copy it to a stable absolute path outside any TCC-protected directory.
cp "$BIN_DIR/pipit-nativehost" "$APP_DIR/Contents/MacOS/pipit-nativehost"
# The command line tool. `pipit` would collide with the `Pipit` executable on a
# case-insensitive volume, so the file is pipit-cli and `pipit-cli install`
# links the name `pipit` to it. The skill it installs ships beside it.
cp "$BIN_DIR/pipit-cli" "$APP_DIR/Contents/MacOS/pipit-cli"
mkdir -p "$APP_DIR/Contents/Resources/skills"
cp -R "$REPO_ROOT/skills/pipit" "$APP_DIR/Contents/Resources/skills/pipit"
cp -R "$REPO_ROOT/extension/dist" "$APP_DIR/Contents/Resources/extension"
# The signed add-on, when scripts/sign-extension.sh has produced one. Without it
# the app falls back to walking the user through about:debugging, which loads the
# extension until Firefox quits.
if [ -f "$REPO_ROOT/extension/signed/pipit-sensor.xpi" ]; then
    cp "$REPO_ROOT/extension/signed/pipit-sensor.xpi" \
        "$APP_DIR/Contents/Resources/extension/pipit-sensor.xpi"
    echo "==> bundled the signed Firefox add-on"
fi
# The Safari extension. Safari reads a web extension only from an app extension
# inside an application, so the add-on's Safari build goes into the bundle's
# Resources and the relay SwiftPM built becomes its executable.
APPEX="$APP_DIR/Contents/PlugIns/PipitSafariExtension.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
cp "$BIN_DIR/pipit-safari-extension" "$APPEX/Contents/MacOS/PipitSafariExtension"
cp -R "$REPO_ROOT/extension/dist/safari/." "$APPEX/Contents/Resources/"
cp "$REPO_ROOT/App/SafariExtension/Info.plist" "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APPEX/Contents/Info.plist"
# Sparkle. SwiftPM unpacks the xcframework into
# .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 and
# copies the macOS slice to .build/<config>/Sparkle.framework as part of the
# build, so the per-config path is the one to take. The executable reaches it
# through the @executable_path/../Frameworks rpath PipitApp links with.
mkdir -p "$APP_DIR/Contents/Frameworks"
[ -d "$BIN_DIR/Sparkle.framework" ] || { echo "no framework at $BIN_DIR/Sparkle.framework. Build first." >&2; exit 1; }
cp -R "$BIN_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
# The echo canceller's models. SwiftPM builds them into the audio module's
# resource bundle; the app reads them from its own Resources.
MODELS="$BIN_DIR/Pipit_PipitAudio.bundle/EchoModels"
[ -d "$MODELS" ] || { echo "no echo models at $MODELS. Build first." >&2; exit 1; }
cp -R "$MODELS" "$APP_DIR/Contents/Resources/EchoModels"
cp "$REPO_ROOT/Assets/Pipit/AppIcons/Pipit.icns" "$APP_DIR/Contents/Resources/Pipit.icns"
for state in idle recording paused warning; do
    cp "$REPO_ROOT/Assets/Pipit/MenuBar/pipit-$state.png" "$APP_DIR/Contents/Resources/"
    cp "$REPO_ROOT/Assets/Pipit/MenuBar/pipit-$state@2x.png" "$APP_DIR/Contents/Resources/"
done

# The two version keys and the commit are the only keys the build stamps.
# Everything else in the bundle plist is what App/Info.plist says.
cp "$REPO_ROOT/App/Info.plist" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :PipitGitCommit $GIT_COMMIT" "$APP_DIR/Contents/Info.plist"

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
# The app group Pipit shares with its Safari extension, which is where the app
# listens for Safari. A Developer ID build prefixes it with the team, which is
# the certificate's organisational unit; Xcode writes the same prefix as
# $(TeamIdentifierPrefix). Ad-hoc and the self-signed development identity have
# no team, and the group goes unprefixed. PIPIT_TEAM_ID overrides the lookup for
# an identity named by its hash.
TEAM_ID="${PIPIT_TEAM_ID:-}"
if [ -z "$TEAM_ID" ] && [ "$IDENTITY" != "-" ]; then
    TEAM_ID="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null \
        | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
        | sed -n -E 's/^ *organizationalUnitName *= *([A-Z0-9]{10}) *$/\1/p' \
        | head -1 || true)"
fi
TEAM_PREFIX="${TEAM_ID:+$TEAM_ID.}"
ENTITLEMENTS_DIR="$(mktemp -d)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT
APP_ENTITLEMENTS="$ENTITLEMENTS_DIR/Pipit.entitlements"
cp "$REPO_ROOT/App/Pipit.entitlements" "$APP_ENTITLEMENTS"
/usr/libexec/PlistBuddy \
    -c "Add :com.apple.security.application-groups array" \
    -c "Add :com.apple.security.application-groups:0 string ${TEAM_PREFIX}com.pipit.sensor" \
    "$APP_ENTITLEMENTS"
SAFARI_ENTITLEMENTS="$ENTITLEMENTS_DIR/PipitSafariExtension.entitlements"
sed "s/\$(TeamIdentifierPrefix)/${TEAM_PREFIX}/" \
    "$REPO_ROOT/App/SafariExtension/PipitSafariExtension.entitlements" >"$SAFARI_ENTITLEMENTS"
echo "==> app group ${TEAM_PREFIX}com.pipit.sensor"

# Sparkle's nested code signs first, innermost outwards, then the framework, then
# the app. --deep is not used. It would re-sign the nested items with the app's
# identifier and entitlements, which Sparkle's helpers do not accept.
SPARKLE="$APP_DIR/Contents/Frameworks/Sparkle.framework"
for nested in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app" \
    "$SPARKLE"; do
    codesign --force --sign "$IDENTITY" \
        --options runtime \
        "${TIMESTAMP[@]}" \
        "$nested"
done

# A stable identifier is what lets the app recognise its own relay when the relay
# connects to the sensor socket.
codesign --force --sign "$IDENTITY" \
    --identifier "com.pipit.nativehost" \
    --options runtime \
    "${TIMESTAMP[@]}" \
    "$APP_DIR/Contents/MacOS/pipit-nativehost"
codesign --force --sign "$IDENTITY" \
    --identifier "com.pipit.cli" \
    --options runtime \
    "${TIMESTAMP[@]}" \
    "$APP_DIR/Contents/MacOS/pipit-cli"
# Signed before the app that contains it, like Sparkle. The identifier is the
# one the app checks when the extension connects to Safari's socket.
codesign --force --sign "$IDENTITY" \
    --identifier "com.pipit.app.safari-extension" \
    --options runtime \
    --entitlements "$SAFARI_ENTITLEMENTS" \
    "${TIMESTAMP[@]}" \
    "$APPEX"
codesign --force --sign "$IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    --entitlements "$APP_ENTITLEMENTS" \
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
