#!/bin/bash
# Print the GitHub release body for one version.
#
#   scripts/release-notes.sh <version>
#   scripts/release-notes.sh <version> <owner/repo> <previous-tag> [<login>...]
#   scripts/release-notes.sh --contributors <owner/repo> <base> <head> <maintainer>
#   scripts/release-notes.sh --self-test
#
# The body is the version's section of CHANGELOG.md, from the line after
# "## <version>" to the next "## " heading, followed by END_MARKER. The update
# window reads the body only up to the marker. With a repository and previous
# tag, the release page also gets, after the marker, a line thanking each
# contributor named and a link comparing the release with the previous one.
# The notes are the page's only list of changes, so GitHub's generated pull
# request list is not added. The script fails when the section is missing or
# empty, so a release never goes out without notes.
#
# --contributors prints the GitHub logins that authored commits between two
# refs, leaving out the maintainer and bots, for the thanks line.
#
# --self-test checks the output against a sample changelog and prints PASS or
# FAIL for each case.
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

# "@a", "@a and @b", "@a, @b and @c".
thanks_line() {
    local list="@$1" login
    shift
    while [ "$#" -gt 1 ]; do list="$list, @$1"; shift; done
    for login in "$@"; do list="$list and @$login"; done
    printf 'Thanks to %s for contributing to this release.' "$list"
}

body() {
    local changelog="$1" version="$2" repository="${3:-}" previous="${4:-}" notes
    shift $(($# < 4 ? $# : 4))
    notes="$(section "$changelog" "$version")"
    if [ -z "$notes" ]; then
        echo "CHANGELOG.md has no notes under \"## $version\". Write them in the release pull request." >&2
        return 1
    fi
    printf '%s\n\n%s\n' "$notes" "$END_MARKER"
    # The first release has nothing to compare with or thank anyone against.
    [ -n "$repository" ] && [ -n "$previous" ] || return 0
    if [ "$#" -gt 0 ]; then printf '\n%s\n' "$(thanks_line "$@")"; fi
    printf '\n**Full Changelog**: https://github.com/%s/compare/%s...v%s\n' \
        "$repository" "$previous" "$version"
}

contributors() {
    local repository="$1" base="$2" head="$3" maintainer="$4"
    gh api "repos/$repository/compare/$base...$head" \
        --jq '.commits[] | select(.author != null and .author.type != "Bot") | .author.login' |
        sort -u | grep -vxF "$maintainer" || true
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

    expected="$(printf '### Fixes\n- Another thing.\n\n%s\n\n%s' "$END_MARKER" \
        "**Full Changelog**: https://github.com/o/r/compare/v0.1.8...v0.1.9")"
    actual="$(body "$sample" 0.1.9 o/r v0.1.8)"
    if [ "$actual" = "$expected" ]; then echo "PASS compare link without thanks"; else
        echo "FAIL compare link without thanks: $actual"; failures=$((failures + 1)); fi

    expected="$(printf '### Fixes\n- Another thing.\n\n%s\n\n%s\n\n%s' "$END_MARKER" \
        "Thanks to @ada for contributing to this release." \
        "**Full Changelog**: https://github.com/o/r/compare/v0.1.8...v0.1.9")"
    actual="$(body "$sample" 0.1.9 o/r v0.1.8 ada)"
    if [ "$actual" = "$expected" ]; then echo "PASS thanks one contributor"; else
        echo "FAIL thanks one contributor: $actual"; failures=$((failures + 1)); fi

    expected="Thanks to @ada, @bo and @cy for contributing to this release."
    actual="$(body "$sample" 0.1.9 o/r v0.1.8 ada bo cy | grep '^Thanks' || true)"
    if [ "$actual" = "$expected" ]; then echo "PASS thanks three contributors"; else
        echo "FAIL thanks three contributors: $actual"; failures=$((failures + 1)); fi

    expected="$(printf 'Summary line.\n\n### New\n- A thing.\n\n%s' "$END_MARKER")"
    actual="$(body "$sample" 0.2.0 o/r "")"
    if [ "$actual" = "$expected" ]; then echo "PASS first release has no compare link"; else
        echo "FAIL first release has no compare link: $actual"; failures=$((failures + 1)); fi

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
    --contributors) shift; contributors "$@" ;;
    "" | -*) echo "usage: scripts/release-notes.sh <version> [<owner/repo> <previous-tag> [<login>...]] | --contributors <owner/repo> <base> <head> <maintainer> | --self-test" >&2; exit 2 ;;
    *) body "$REPO_ROOT/CHANGELOG.md" "$@" ;;
esac
