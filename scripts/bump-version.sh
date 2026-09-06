#!/bin/bash
# Print the next version after a bump. Usage: scripts/bump-version.sh <patch|minor|major>
#
# It reads the current version from the repository's VERSION file and writes
# the bumped version to stdout. It changes no files, so the caller decides what
# to do with the number. The release workflow calls it to turn a bump level
# into the version it tags.
#
# scripts/bump-version.sh --apply <version> writes that version into the tree:
# VERSION, MARKETING_VERSION in project.yml, and the generated Xcode project.
#
# scripts/bump-version.sh --self-test checks the arithmetic against a table of
# cases and prints PASS or FAIL for each.
set -euo pipefail

# Split MAJOR.MINOR.PATCH, raise the requested field, and zero the fields below
# it. Bash arithmetic only, so the script runs on a bare macOS runner.
next_version() {
    local current="$1" level="$2"
    case "$current" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) echo "version must be MAJOR.MINOR.PATCH, got: $current" >&2; return 1 ;;
    esac
    local major="${current%%.*}"
    local rest="${current#*.}"
    local minor="${rest%%.*}"
    local patch="${rest#*.}"
    case "$major$minor$patch" in
        *[!0-9]*) echo "version fields must be numeric, got: $current" >&2; return 1 ;;
    esac
    case "$level" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *) echo "level must be patch, minor, or major, got: $level" >&2; return 1 ;;
    esac
}

self_test() {
    local failures=0
    local case_line current level expected actual
    for case_line in \
        "0.1.0 patch 0.1.1" \
        "0.1.9 minor 0.2.0" \
        "0.9.3 major 1.0.0" \
        "1.2.3 major 2.0.0" \
        "1.2.3 minor 1.3.0" \
        "1.2.9 patch 1.2.10"; do
        read -r current level expected <<<"$case_line"
        actual="$(next_version "$current" "$level")"
        if [ "$actual" = "$expected" ]; then
            echo "PASS $current $level -> $actual"
        else
            echo "FAIL $current $level -> $actual, expected $expected"
            failures=$((failures + 1))
        fi
    done
    if next_version "1.2" patch >/dev/null 2>&1; then
        echo "FAIL 1.2 patch was accepted"
        failures=$((failures + 1))
    else
        echo "PASS 1.2 patch is rejected"
    fi
    if next_version "1.2.3" sideways >/dev/null 2>&1; then
        echo "FAIL sideways was accepted as a level"
        failures=$((failures + 1))
    else
        echo "PASS sideways is rejected as a level"
    fi
    [ "$failures" -eq 0 ]
}

# Write a version into the tree. VERSION and project.yml are the two files that
# hold it. Pipit.xcodeproj is generated from project.yml, so it is regenerated
# here when xcodegen is available and left to the caller when it is not.
apply_version() {
    local version="$1"
    case "$version" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *) echo "version must be MAJOR.MINOR.PATCH, got: $version" >&2; return 1 ;;
    esac
    printf '%s\n' "$version" > "$REPO_ROOT/VERSION"
    local project="$REPO_ROOT/project.yml"
    if ! grep -q '^ *MARKETING_VERSION:' "$project"; then
        echo "no MARKETING_VERSION in $project" >&2
        return 1
    fi
    sed -i '' -E "s/^([[:space:]]*MARKETING_VERSION:).*/\\1 \"$version\"/" "$project"
    if command -v xcodegen >/dev/null 2>&1; then
        (cd "$REPO_ROOT" && xcodegen generate >/dev/null)
    else
        echo "xcodegen is not on the PATH; regenerate Pipit.xcodeproj before committing" >&2
    fi
    echo "$version"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "${1-}" in
    --self-test)
        self_test
        ;;
    --apply)
        if [ -z "${2-}" ]; then
            echo "usage: scripts/bump-version.sh --apply <version>" >&2
            exit 2
        fi
        apply_version "$2"
        ;;
    patch|minor|major)
        current="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"
        next_version "$current" "$1"
        ;;
    *)
        echo "usage: scripts/bump-version.sh <patch|minor|major|--apply VERSION|--self-test>" >&2
        exit 2
        ;;
esac
