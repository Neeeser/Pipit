#!/bin/bash
# Builds the Sparkle appcast for one release and signs its archive.
#
# Usage: scripts/make-appcast.sh <version> <archive> <download-url-prefix> [--beta]
#
#   version              Release version without the leading v, such as 0.1.0.
#   archive              The zip or dmg users download, such as
#                        dist/Pipit-0.1.0.zip.
#   download-url-prefix  Where that file will live, ending in a slash. For a
#                        GitHub release asset:
#                        https://github.com/Neeeser/Pipit/releases/download/v0.1.0/
#   --beta               Publish on the beta channel. A version starting with
#                        "0." is a beta whether or not the flag is passed.
#
# The private key comes from SPARKLE_PRIVATE_KEY: the base64 key on one line,
# as generate_keys prints it. The script writes it to a file only because
# generate_appcast reads keys from a file or the keychain, and removes that
# file on exit.
#
# The appcast is written to APPCAST_DIR (dist/appcast by default). Put the
# published appcast.xml there first and generate_appcast keeps its items, so
# users on older versions still find an update. Keep every other archive out of
# that directory. generate_appcast rewrites the download URL of any item whose
# archive it finds there, and builds delta files nothing uploads.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="${1:?usage: make-appcast.sh <version> <archive> <download-url-prefix> [--beta]}"
ARCHIVE="${2:?usage: make-appcast.sh <version> <archive> <download-url-prefix> [--beta]}"
DOWNLOAD_PREFIX="${3:?usage: make-appcast.sh <version> <archive> <download-url-prefix> [--beta]}"
BETA_FLAG="${4:-}"

: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}"
test -e "$ARCHIVE" || { echo "no such archive: $ARCHIVE" >&2; exit 1; }

# Sparkle 2.9.6, the version Package.swift pins. The hash covers the release
# archive that carries generate_appcast, generate_keys and sign_update.
SPARKLE_VERSION="2.9.6"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"

TOOLS_DIR="${SPARKLE_TOOLS_DIR:-$REPO_ROOT/.build/sparkle-$SPARKLE_VERSION}"
APPCAST_DIR="${APPCAST_DIR:-$REPO_ROOT/dist/appcast}"
LINK="https://github.com/Neeeser/Pipit/releases"
RELEASE_NOTES_LINK="https://github.com/Neeeser/Pipit/releases/tag/v$VERSION"

if [ ! -x "$TOOLS_DIR/bin/generate_appcast" ]; then
    echo "==> fetching Sparkle $SPARKLE_VERSION tools"
    mkdir -p "$TOOLS_DIR"
    TARBALL="$TOOLS_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
    curl -fsSL -o "$TARBALL" "$SPARKLE_URL"
    ACTUAL="$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)"
    if [ "$ACTUAL" != "$SPARKLE_SHA256" ]; then
        echo "Sparkle archive hash mismatch: expected $SPARKLE_SHA256, got $ACTUAL" >&2
        exit 1
    fi
    tar -xJf "$TARBALL" -C "$TOOLS_DIR"
fi

KEY_FILE="$(mktemp -t sparkle-key)"
trap 'rm -f "$KEY_FILE"' EXIT INT TERM
chmod 600 "$KEY_FILE"
printf '%s\n' "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

mkdir -p "$APPCAST_DIR"
cp "$ARCHIVE" "$APPCAST_DIR/"

CHANNEL_ARGS=()
if [ "$BETA_FLAG" = "--beta" ] || [ "${VERSION%%.*}" = "0" ]; then
    CHANNEL_ARGS=(--channel beta)
    echo "==> publishing $VERSION on the beta channel"
fi

echo "==> generating the appcast"
"$TOOLS_DIR/bin/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --link "$LINK" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    ${CHANNEL_ARGS[@]+"${CHANNEL_ARGS[@]}"} \
    "$APPCAST_DIR"

# generate_appcast writes a releaseNotesLink only for a notes file sitting next
# to the archive. Pipit's notes live on the GitHub release page, so the link is
# added here. The appcast itself carries no signature, only each enclosure does,
# so editing the file after the tool runs does not invalidate anything. That
# holds only while App/Info.plist sets no appcast signature key. Add one and
# this edit starts breaking the feed.
APPCAST="$APPCAST_DIR/appcast.xml" VERSION="$VERSION" NOTES="$RELEASE_NOTES_LINK" python3 - <<'PYTHON'
import os
import re

path = os.environ["APPCAST"]
version = os.environ["VERSION"]
notes = os.environ["NOTES"]
text = open(path, encoding="utf-8").read()


def add_link(match):
    item = match.group(0)
    if "releaseNotesLink" in item:
        return item
    if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in item:
        return item
    return item.replace(
        "<sparkle:version>",
        f"<sparkle:releaseNotesLink>{notes}</sparkle:releaseNotesLink>\n            <sparkle:version>",
        1,
    )


updated = re.sub(r"<item>.*?</item>", add_link, text, flags=re.DOTALL)
if updated != text:
    open(path, "w", encoding="utf-8").write(updated)
PYTHON

# An enclosure without a signature is an update Sparkle will refuse. The tool
# signs only when the app inside the archive carries SUPublicEDKey, so a
# placeholder key in App/Info.plist fails here rather than at update time.
if ! grep "$(basename "$ARCHIVE")\"" "$APPCAST_DIR/appcast.xml" | grep -q 'sparkle:edSignature'; then
    echo "appcast has no edSignature: check SUPublicEDKey in the bundled Info.plist" >&2
    exit 1
fi

echo "==> wrote $APPCAST_DIR/appcast.xml"
