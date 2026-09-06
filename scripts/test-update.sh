#!/bin/bash
# Runs one Sparkle update end to end against a local feed.
#
# Usage: scripts/test-update.sh [debug|release]
#
# The script builds Pipit once, makes two copies of the bundle, stamps the
# second one patch higher, signs both, publishes the newer one through an
# appcast served from 127.0.0.1, installs the older one under ~/PipitUpdateTest
# and launches it. It passes when the installed bundle's CFBundleVersion has
# become the newer number.
#
# Both copies get a throwaway EdDSA public key written into their Info.plist,
# because App/Info.plist still carries the placeholder key. Rewriting a plist
# breaks the signature, so the copies are signed after the edit, nested items
# first, the same order scripts/bundle-app.sh uses.
#
# Sparkle requires the installed app and the update to carry the same signing
# identity. The Developer ID identity is used when the login keychain has one,
# ad-hoc otherwise, and both copies take the same route either way.
#
# The copies carry their own bundle identifier, so the user defaults Sparkle
# reads and its download cache stay away from an installed Pipit. The defaults,
# the cache and the install directory are removed at the end.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$REPO_ROOT/App/Info.plist")"
TEST_BUNDLE_ID="$BUNDLE_ID.updatetest"
OLD_VERSION="$(cat "$REPO_ROOT/VERSION")"
NEW_VERSION="${OLD_VERSION%.*}.$((${OLD_VERSION##*.} + 1))"
# Sparkle orders updates by CFBundleVersion, so the build number moves with the
# marketing version.
OLD_BUILD=1
NEW_BUILD=2
# How long to wait for the download and the install on quit.
DOWNLOAD_WAIT="${PIPIT_UPDATE_DOWNLOAD_WAIT:-90}"
INSTALL_WAIT="${PIPIT_UPDATE_INSTALL_WAIT:-120}"

WORK="$(mktemp -d -t pipit-update)"
SERVE_DIR="$WORK/feed"
# The older copy is installed here rather than in the work directory. An app run
# from the temp directory is sent a quit AppleEvent a fraction of a second after
# it launches, which cuts the installer off part way through staging and the
# update is thrown away.
INSTALL_DIR="$HOME/PipitUpdateTest"
LOG_FILE="$WORK/sparkle.log"
KEY_FILE="$WORK/ed25519.key"
# The keychain account the throwaway signing key is made under and deleted from.
KEY_ACCOUNT="pipit-update-test"
SERVER_PID=""
LOG_PID=""
rm -rf "$INSTALL_DIR"
mkdir -p "$SERVE_DIR" "$INSTALL_DIR"

cleanup() {
    [ -n "$SERVER_PID" ] && { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
    [ -n "$LOG_PID" ] && { kill "$LOG_PID" 2>/dev/null || true; wait "$LOG_PID" 2>/dev/null || true; }
    pkill -f "$INSTALL_DIR/Pipit.app" 2>/dev/null || true
    defaults delete "$TEST_BUNDLE_ID" >/dev/null 2>&1 || true
    security delete-generic-password -a "$KEY_ACCOUNT" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$TEST_BUNDLE_ID.sparkle" "$INSTALL_DIR"
    if [ -n "${PIPIT_KEEP_WORK:-}" ]; then
        echo "==> work kept at $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

# Signs one bundle the way scripts/bundle-app.sh does: Sparkle's nested code
# first, innermost outwards, then the framework, then the app. --deep is not
# used, because it would re-sign the nested items with the app's identifier.
sign_bundle() {
    local app="$1"
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    for nested in \
        "$sparkle/Versions/B/XPCServices/Installer.xpc" \
        "$sparkle/Versions/B/XPCServices/Downloader.xpc" \
        "$sparkle/Versions/B/Autoupdate" \
        "$sparkle/Versions/B/Updater.app" \
        "$sparkle"; do
        codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$nested"
    done
    codesign --force --sign "$IDENTITY" \
        --identifier "com.pipit.nativehost" \
        --options runtime --timestamp=none \
        "$app/Contents/MacOS/pipit-nativehost"
    codesign --force --sign "$IDENTITY" \
        --identifier "$TEST_BUNDLE_ID" \
        --options runtime \
        --entitlements "$REPO_ROOT/App/Pipit.entitlements" \
        --timestamp=none \
        "$app"
}

installed_build() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
        "$INSTALL_DIR/Pipit.app/Contents/Info.plist" 2>/dev/null || echo "?"
}

fail() {
    echo
    echo "FAIL: $1"
    echo "--- Sparkle log ---"
    tail -60 "$LOG_FILE" 2>/dev/null || echo "(no log)"
    exit 1
}

echo "==> building Pipit ($CONFIG)"
"$REPO_ROOT/scripts/bundle-app.sh" "$CONFIG" > "$WORK/build.log" 2>&1 ||
    { tail -20 "$WORK/build.log"; echo "build failed, see $WORK/build.log" >&2; exit 1; }

# generate_keys is the only way to a key pair Sparkle agrees with. It stores
# the pair in the login keychain under an account name, so the test uses its own
# account and deletes that item as soon as the key is exported. Signing keys
# Andrew generated under the default account are untouched.
# scripts/make-appcast.sh downloads the same archive and checks the same hash.
SPARKLE_VERSION="2.9.6"
SPARKLE_TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$REPO_ROOT/.build/sparkle-$SPARKLE_VERSION}"
if [ ! -x "$SPARKLE_TOOLS_DIR/bin/generate_keys" ]; then
    echo "==> fetching Sparkle $SPARKLE_VERSION tools"
    mkdir -p "$SPARKLE_TOOLS_DIR"
    TARBALL="$SPARKLE_TOOLS_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fsSL -o "$TARBALL" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    ACTUAL="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
    EXPECTED="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
    [ "$ACTUAL" = "$EXPECTED" ] || fail "Sparkle archive hash mismatch: expected $EXPECTED, got $ACTUAL"
    tar -xJf "$TARBALL" -C "$SPARKLE_TOOLS_DIR"
fi

echo "==> making a throwaway signing key"
"$SPARKLE_TOOLS_DIR/bin/generate_keys" --account "$KEY_ACCOUNT" >/dev/null
PUBLIC_KEY="$("$SPARKLE_TOOLS_DIR/bin/generate_keys" --account "$KEY_ACCOUNT" -p)"
"$SPARKLE_TOOLS_DIR/bin/generate_keys" --account "$KEY_ACCOUNT" -x "$KEY_FILE" >/dev/null
security delete-generic-password -a "$KEY_ACCOUNT" >/dev/null 2>&1 || true
chmod 600 "$KEY_FILE"
PRIVATE_KEY="$(cat "$KEY_FILE")"
[ -n "$PUBLIC_KEY" ] || fail "no public key was generated"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
FEED_URL="http://127.0.0.1:$PORT/appcast.xml"

IDENTITY="${PIPIT_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)"
fi
IDENTITY="${IDENTITY:--}"
echo "==> signing both copies as ${IDENTITY}"

# Both copies point at the local feed and carry the throwaway public key.
# SUAllowsAutomaticUpdates and SUAutomaticallyUpdate together let Sparkle
# install on quit without a click, which is what makes the test unattended.
prepare_copy() {
    local app="$1" version="$2" build="$3"
    rm -rf "$app"
    mkdir -p "$(dirname "$app")"
    cp -R "$REPO_ROOT/dist/Pipit.app" "$app"
    local plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TEST_BUNDLE_ID" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL $FEED_URL" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$plist"
    /usr/libexec/PlistBuddy -c "Set :SUAllowsAutomaticUpdates true" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$plist"
    sign_bundle "$app"
}

echo "==> staging $OLD_VERSION ($OLD_BUILD) and $NEW_VERSION ($NEW_BUILD)"
prepare_copy "$INSTALL_DIR/Pipit.app" "$OLD_VERSION" "$OLD_BUILD"
prepare_copy "$WORK/new/Pipit.app" "$NEW_VERSION" "$NEW_BUILD"

echo "==> packaging $NEW_VERSION"
ARCHIVE="$WORK/Pipit-$NEW_VERSION.zip"
ditto -c -k --keepParent "$WORK/new/Pipit.app" "$ARCHIVE"

echo "==> publishing the appcast"
SPARKLE_PRIVATE_KEY="$PRIVATE_KEY" APPCAST_DIR="$SERVE_DIR" SPARKLE_TOOLS_DIR="$SPARKLE_TOOLS_DIR" \
    "$REPO_ROOT/scripts/make-appcast.sh" "$NEW_VERSION" "$ARCHIVE" "http://127.0.0.1:$PORT/" \
    > "$WORK/appcast.log" 2>&1 ||
    { tail -20 "$WORK/appcast.log"; fail "make-appcast.sh failed"; }

echo "==> serving $SERVE_DIR on 127.0.0.1:$PORT"
(cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
    > "$WORK/server.log" 2>&1 &
SERVER_PID=$!

log stream --level info --style compact \
    --predicate 'subsystem == "org.sparkle-project.Sparkle" OR subsystem BEGINSWITH "com.pipit"' \
    > "$LOG_FILE" 2>&1 &
LOG_PID=$!

# Sparkle runs a scheduled check shortly after launch when automatic checks are
# on and the last check is older than the interval. SUHasLaunchedBefore skips
# the first-launch delay, and installing without a click needs
# SUAutomaticallyUpdate on top of the plist's SUAllowsAutomaticUpdates.
defaults write "$TEST_BUNDLE_ID" SUEnableAutomaticChecks -bool true
defaults write "$TEST_BUNDLE_ID" SUAutomaticallyUpdate -bool true
defaults write "$TEST_BUNDLE_ID" SUScheduledCheckInterval -int 3600
defaults write "$TEST_BUNDLE_ID" SUHasLaunchedBefore -bool true
defaults write "$TEST_BUNDLE_ID" SULastCheckTime -date "2001-01-01 00:00:00 +0000"

echo "==> launching the installed $OLD_VERSION"
open -n -a "$INSTALL_DIR/Pipit.app"

echo "==> waiting up to ${DOWNLOAD_WAIT}s for the download and its signature check"
downloaded=0
for _ in $(seq "$DOWNLOAD_WAIT"); do
    sleep 1
    if grep -qE 'EdDSA signature is correct|ready to install' "$LOG_FILE"; then
        downloaded=1
        break
    fi
    [ "$(installed_build)" = "$NEW_BUILD" ] && { downloaded=1; break; }
done
[ "$downloaded" = 1 ] || fail "no update passed its signature check within ${DOWNLOAD_WAIT}s"

echo "==> quitting so the update installs"
osascript -e "quit app id \"$TEST_BUNDLE_ID\"" >/dev/null 2>&1 || pkill -f "$INSTALL_DIR/Pipit.app" || true

echo "==> waiting up to ${INSTALL_WAIT}s for the installed version to change"
for _ in $(seq "$INSTALL_WAIT"); do
    [ "$(installed_build)" = "$NEW_BUILD" ] && break
    sleep 1
done

FINAL_BUILD="$(installed_build)"
FINAL_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$INSTALL_DIR/Pipit.app/Contents/Info.plist" 2>/dev/null || echo "?")"
pkill -f "$INSTALL_DIR/Pipit.app" 2>/dev/null || true

if [ "$FINAL_BUILD" = "$NEW_BUILD" ]; then
    echo
    echo "PASS: the installed app moved from $OLD_VERSION ($OLD_BUILD) to $FINAL_VERSION ($FINAL_BUILD)"
    grep -E 'Sparkle\]' "$LOG_FILE" | tail -12
    exit 0
fi

fail "the installed app is still $FINAL_VERSION ($FINAL_BUILD)"
