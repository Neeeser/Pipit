#!/bin/bash
# Prints the suite types tagged `.slow`, one per line, or with --regex an
# extended regular expression that matches their test identifiers.
#
# SwiftPM can select tests by name only, and the tag is the one place a suite
# says it is slow. So the names are read from the sources: the `@Suite` line
# that carries `.tags(.slow)` followed by the declaration of the type. A suite
# is tagged with `@Suite("Name", .tags(.slow))` on one line.
#
# Usage: scripts/slow-suites.sh [--regex]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

suites="$(find Tests -name '*.swift' -print0 | xargs -0 awk '
    /^[[:space:]]*@Suite\(.*\.tags\(.*\.slow/ { pending = 1; next }
    pending && /(struct|class|actor|enum) [A-Za-z_][A-Za-z0-9_]*/ {
        match($0, /(struct|class|actor|enum) [A-Za-z_][A-Za-z0-9_]*/)
        split(substr($0, RSTART, RLENGTH), parts, " ")
        print parts[2]
        pending = 0
    }
' | sort -u)"

# A tag the awk above cannot attach to a type would leave a slow test running
# in the fast pass without a sound. Count the attributes that use the tag and
# the types they named. A `@Test` tagged alone is counted here and fails.
tagged="$(grep -rEc '^[[:space:]]*@(Suite|Test)\(.*\.slow' Tests --include='*.swift' | awk -F: '{ n += $2 } END { print n + 0 }')"
found="$(printf '%s\n' "$suites" | grep -c . || true)"
if [ "$tagged" -ne "$found" ]; then
    echo "slow-suites: $tagged uses of .slow, but $found suite types found." >&2
    echo "Tag a suite as @Suite(\"Name\", .tags(.slow)) on one line, above its type." >&2
    exit 1
fi

if [ "${1:-}" = "--regex" ]; then
    printf '%s\n' "$suites" | paste -sd'|' - | sed -E 's/^(.*)$/(^|\\.)(\1)\//'
else
    printf '%s\n' "$suites"
fi
