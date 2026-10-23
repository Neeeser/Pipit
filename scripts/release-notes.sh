#!/bin/bash
# Print the GitHub release body for one version. Usage: scripts/release-notes.sh <version>
#
# The body is the version's section of CHANGELOG.md, from the line after
# "## <version>" to the next "## " heading, followed by END_MARKER. The update
# window reads the body only up to the marker, so the pull request list GitHub
# appends after it stays on the release page. The script fails when the section
# is missing or empty, so a release never goes out without notes.
#
# scripts/release-notes.sh --self-test checks the extraction against a sample
# changelog and prints PASS or FAIL for each case.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Must match ReleaseNotes.endMarker in Sources/PipitUI/Updates/ReleaseNotes.swift.
END_MARKER="<!-- pipit:end-of-app-notes -->"

# The section's lines with leading and trailing blank lines removed.
section() {
    local changelog="$1" version="$2"
    awk -v heading="## $version" '
        $0 == heading { inside = 1; next }
        inside && /^## / { exit }
        inside { lines[++count] = $0 }
        END {
            first = 1
            while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
            last = count
            while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    ' "$changelog"
}

body() {
    local changelog="$1" version="$2" notes
    notes="$(section "$changelog" "$version")"
    if [ -z "$notes" ]; then
        echo "CHANGELOG.md has no notes under \"## $version\". Write them in the release pull request." >&2
        return 1
    fi
    printf '%s\n\n%s\n' "$notes" "$END_MARKER"
}

self_test() {
    local failures=0 sample actual expected
    sample="$(mktemp)"
    trap 'rm -f "$sample"' RETURN
    cat >"$sample" <<'EOF'
# Changelog

## 0.2.0

Summary line.

### New
- A thing.

## 0.1.9

### Fixes
- Another thing.

## 0.1.8
EOF

    expected="$(printf 'Summary line.\n\n### New\n- A thing.\n\n%s' "$END_MARKER")"
    actual="$(body "$sample" 0.2.0)"
    if [ "$actual" = "$expected" ]; then echo "PASS first section"; else
        echo "FAIL first section: $actual"; failures=$((failures + 1)); fi

    expected="$(printf '### Fixes\n- Another thing.\n\n%s' "$END_MARKER")"
    actual="$(body "$sample" 0.1.9)"
    if [ "$actual" = "$expected" ]; then echo "PASS middle section"; else
        echo "FAIL middle section: $actual"; failures=$((failures + 1)); fi

    for missing in 0.1.8 0.3.0 0.2; do
        if body "$sample" "$missing" >/dev/null 2>&1; then
            echo "FAIL $missing was accepted"; failures=$((failures + 1))
        else
            echo "PASS $missing is refused"
        fi
    done
    [ "$failures" -eq 0 ]
}

case "${1:-}" in
    --self-test) self_test ;;
    "" | -*) echo "usage: scripts/release-notes.sh <version> | --self-test" >&2; exit 2 ;;
    *) body "$REPO_ROOT/CHANGELOG.md" "$1" ;;
esac
