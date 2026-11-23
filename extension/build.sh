#!/bin/bash
# Assembles loadable extension directories for each browser.
#
# The sources are ES modules so they can be unit tested under Node, but a content
# script cannot be a module: an `import` statement makes the whole script fail to
# load and the sensor silently never runs. The build therefore strips the module
# syntax and ships plain scripts that share the content-script scope.
#
# Firefox uses MV2 with a background page; Chrome needs MV3 with a service
# worker; Safari takes MV3 with a background page it unloads when idle. The
# observation code is identical, so only the manifest differs. The Chrome build
# also loads unchanged in Brave, Edge, Arc and Vivaldi. The Safari build is not
# loadable on its own: scripts/bundle-app.sh puts it inside the app extension
# Safari reads it from.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST="$ROOT/dist"
rm -rf "$DIST"

# Strips the module syntax the sources use: `export ` prefixes, the imports
# between shared files, and the re-export provider.js makes for the tests.
plain() {
    sed -E \
        -e 's/^export (function|const|let|class)/\1/' \
        -e "/^import .* from '\.\/(sites\.js|meeting-sites\.json)'.*;$/d" \
        -e '/^export \{.*\};$/d' \
        "$1"
}

# sites.js goes in front of both provider.js and the background script, with
# meeting-sites.json written in as a constant where sites.js imports it.
# Content scripts share one scope, so provider.js then finds its site helpers
# already defined.
sites() {
    printf 'const MEETING_SITES = %s;\n' "$(cat "$ROOT/shared/meeting-sites.json")"
    plain "$ROOT/shared/sites.js"
}

for browser in firefox chrome safari; do
    mkdir -p "$DIST/$browser/shared"
    {
        sites
        plain "$ROOT/shared/provider.js"
    } > "$DIST/$browser/shared/provider.js"
    cp "$ROOT/shared/content.js" "$DIST/$browser/shared/content.js"
    # relay.js is testable on its own, and background.js calls it. A Chrome MV3
    # service worker names one file, so the three are concatenated instead of
    # being listed in the manifest. The other two take the same file.
    {
        sites
        plain "$ROOT/shared/relay.js"
        cat "$ROOT/shared/background.js"
    } > "$DIST/$browser/shared/background.js"
    cp "$ROOT/$browser/manifest.json" "$DIST/$browser/manifest.json"
    # The app icon, which is what the browser shows in its add-on list and in
    # the install prompt. Without it the browser draws a generic puzzle piece.
    cp -R "$ROOT/icons" "$DIST/$browser/icons"

    for file in provider.js content.js background.js; do
        if grep -qE '^\s*(import|export)\s' "$DIST/$browser/shared/$file"; then
            echo "module syntax survived in $browser/shared/$file" >&2
            exit 1
        fi
    done
    node --check "$DIST/$browser/shared/provider.js"
    node --check "$DIST/$browser/shared/content.js"
    node --check "$DIST/$browser/shared/background.js"
    echo "built $DIST/$browser"
done
