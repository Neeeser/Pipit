#!/bin/bash
# Writes the debug symbols for the three executables in dist/Pipit.app and
# checks that they symbolicate those exact binaries.
#
# A crash report from someone else's Mac names frames as an image and an
# offset. Turning that into a function and a line takes a dSYM with the same
# UUID. The linker derives the UUID from the output, so a later rebuild of the
# same commit matches only if it comes out byte for byte the same, which
# nothing here guarantees. So the symbols are written from the build that was
# bundled, before its object files are gone, and archived beside the release.
#
# The check is what keeps a release from shipping without usable symbols. Each
# dSYM must carry the UUIDs of the bundled binary for every architecture it
# holds, and `atos` must resolve code to a Swift source line twice: `main` in
# the app target, and a function of PipitCore, which is linked in from a package
# module. A dSYM with no line tables, or one that missed the modules, fails
# here. No PipitCore function is named outright. Cross-module optimisation can
# inline a small public function and the linker then drops its symbol, and
# many symbols are compiler-generated accessors with no line at all, so the
# check takes the first of the module's symbols that resolves to a line.
#
# Usage: scripts/archive-dsyms.sh [version]
# Writes dist/dSYMs/<name>.dSYM and dist/Pipit-<version>-dSYMs.zip. The version
# defaults to the bundle's short version.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Pipit.app"
BIN_DIR="$REPO_ROOT/.build/release"
OUT="$REPO_ROOT/dist"

test -d "$APP" || { echo "build the app first: scripts/bundle-app.sh release" >&2; exit 1; }
VERSION="${1:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")}"

SYMBOLS="$OUT/dSYMs"
rm -rf "$SYMBOLS"
mkdir -p "$SYMBOLS"

uuids() {
    # `dwarfdump --uuid` prints "UUID: <uuid> (<arch>) <path>". The path
    # differs between a binary and its dSYM, so only the first three fields
    # are compared.
    xcrun dwarfdump --uuid "$1" | awk '{ print $1, $2, $3 }' | sort
}

# Prints the first of up to 50 text symbols matching $3 that atos resolves to
# a Swift file and a line, and fails when none does. A compiler-generated
# symbol resolves to `<compiler-generated>:0`, which does not count.
#
# Each command's output is captured whole before the next reads it. Piping into
# `head` or `grep -m1` would end the writer with SIGPIPE, which pipefail turns
# into a failure of a check that had passed.
resolve_to_line() {
    local dwarf="$1" binary="$2" pattern="$3" arch="$4" symbols addresses resolved
    symbols="$(xcrun nm -arch "$arch" -defined-only "$binary")"
    addresses="$(awk -v p="$pattern" '($2 == "T" || $2 == "t") && $3 ~ p && n++ < 50 { print "0x" $1 }' \
        <<<"$symbols")"
    [ -n "$addresses" ] || { echo "no text symbol matching $pattern in $binary ($arch)" >&2; return 1; }
    # atos takes many addresses at once and prints one line for each.
    # shellcheck disable=SC2086
    resolved="$(xcrun atos -arch "$arch" -o "$dwarf" $addresses)"
    grep -m1 -E '[.]swift:[1-9][0-9]*[)]' <<<"$resolved"
}

for name in Pipit pipit-nativehost pipit-cli; do
    binary="$APP/Contents/MacOS/$name"
    dsym="$SYMBOLS/$name.dSYM"
    xcrun dsymutil "$BIN_DIR/$name" -o "$dsym"
    if [ "$(uuids "$binary")" != "$(uuids "$dsym")" ]; then
        echo "the dSYM for $name does not match the bundled binary:" >&2
        uuids "$binary" >&2
        uuids "$dsym" >&2
        exit 1
    fi
    echo "==> $name: $(uuids "$dsym" | awk '{ printf "%s %s  ", $2, $3 }')"
done

dwarf="$SYMBOLS/Pipit.dSYM/Contents/Resources/DWARF/Pipit"
for arch in $(xcrun lipo -archs "$APP/Contents/MacOS/Pipit"); do
    # awk reads the pattern through -v, which processes backslash escapes, so
    # the literal dollar of a mangled Swift name is written as a bracket.
    for pattern in '^_main$' '^_[$]s9PipitCore'; do
        if ! resolved="$(resolve_to_line "$dwarf" "$APP/Contents/MacOS/Pipit" "$pattern" "$arch")"; then
            echo "atos resolved no symbol matching $pattern to a Swift line on $arch" >&2
            exit 1
        fi
        echo "==> $arch $pattern: $resolved"
    done
done

ARCHIVE="$OUT/Pipit-$VERSION-dSYMs.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$SYMBOLS" "$ARCHIVE"
echo "==> wrote $ARCHIVE"
