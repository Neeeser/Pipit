#!/bin/bash
# Prints what a Pipit build stamps into its Info.plist: the short version on the
# first line, the build number on the second, and the full commit on the third.
#
# scripts/bundle-app.sh and the run script phase in project.yml both read it, so
# a bundle assembled either way carries the same three values.
#
# The build number is the commit count. It rises with every commit, so any two
# checkouts are ordered, and Sparkle compares it to decide whether a feed item
# is newer than the running copy.
#
# The short version is what VERSION says when PIPIT_RELEASE=1 is set, which the
# release workflow does. Every other build names the release it leads up to, so
# it sorts after the release it was built from under SemVer:
#
# - Past the v<VERSION> tag, VERSION is already out, and the build previews the
#   next patch: VERSION 0.1.10 reads 0.1.11-dev.<short sha>.
# - On the tagged commit itself, the source is the release, and the build reads
#   plain VERSION. PipitGitCommit and the build configuration still tell a local
#   build from the published one.
# - With no v<VERSION> tag behind HEAD, VERSION is the release still to come, as
#   on a release pull request, and the build reads <VERSION>-dev.<short sha>. A
#   clone that never fetched tags reads this way too.
# - With no git, the release state is unknown, and the build reads
#   <VERSION>-dev.
#
# A dirty working tree adds nothing, so the sha names the commit the build
# started from and nothing more. A tree with no VERSION reads 0.0.0-dev, which
# claims no release, and a release build of it fails.
#
# The commit goes into PipitGitCommit. A release reads plain VERSION, so this
# is what names the exact source of a released build, and it is the key that
# picks the debug symbols for a crash report. A tree with no git prints
# `unknown`.
#
# PIPIT_BUILD_NUMBER overrides the commit count.
#
# scripts/app-version.sh --self-test builds throwaway repositories, runs a copy
# of this script in each, and prints PASS or FAIL for every case.
#
# Usage: scripts/app-version.sh [--self-test]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$REPO_ROOT/scripts/app-version.sh"

self_test() {
    local work
    work="$(mktemp -d)"
    work="$(cd "$work" && pwd -P)"
    # shellcheck disable=SC2064 # expand now, the variable is local
    trap "rm -rf '$work'" EXIT
    # Git must not find the repository the test runs from when a case has none.
    export GIT_CEILING_DIRECTORIES="$work"
    local failures=0

    # Each case gets its own tree with a copy of this script in scripts/.
    new_tree() {
        local dir="$work/$1"
        mkdir -p "$dir/scripts"
        cp "$SELF" "$dir/scripts/app-version.sh"
        echo "$dir"
    }
    git_in() {
        git -C "$1" -c user.name=test -c user.email=test@example.invalid \
            -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}"
    }
    commit_version() {
        local dir="$1" version="$2"
        if [ -n "$version" ]; then printf '%s\n' "$version" >"$dir/VERSION"; fi
        echo "$RANDOM" >>"$dir/notes.txt"
        git_in "$dir" add -A
        git_in "$dir" commit -q -m "set $version"
    }
    check() {
        local name="$1" expected="$2" dir="$3" release="${4:-}"
        local actual
        if actual="$(PIPIT_RELEASE="$release" "$dir/scripts/app-version.sh" 2>/dev/null | head -1)"; then :; else actual="(failed)"; fi
        if [ "$actual" = "$expected" ]; then
            echo "PASS $name: $actual"
        else
            echo "FAIL $name: $actual, expected $expected"
            failures=$((failures + 1))
        fi
    }
    sha_of() { git -C "$1" rev-parse --short=7 HEAD; }

    local dir
    # Commits after a release preview the next patch.
    dir="$(new_tree after-release)"
    git_in "$dir" init -q
    commit_version "$dir" 0.1.10
    git_in "$dir" tag v0.1.10
    commit_version "$dir" ""
    check "after the v0.1.10 tag" "0.1.11-dev.$(sha_of "$dir")" "$dir"
    check "after the v0.1.10 tag, release build" "0.1.10" "$dir" 1

    # The tagged commit itself is the release's source.
    dir="$(new_tree at-tag)"
    git_in "$dir" init -q
    commit_version "$dir" 0.1.10
    git_in "$dir" tag v0.1.10
    check "on the v0.1.10 commit" "0.1.10" "$dir"

    # A patch of 9 rolls to 10, not to 0.
    dir="$(new_tree roll)"
    git_in "$dir" init -q
    commit_version "$dir" 1.2.9
    git_in "$dir" tag v1.2.9
    commit_version "$dir" ""
    check "after the v1.2.9 tag" "1.2.10-dev.$(sha_of "$dir")" "$dir"

    # A release pull request raises VERSION before its tag exists.
    dir="$(new_tree release-pr)"
    git_in "$dir" init -q
    commit_version "$dir" 0.1.10
    git_in "$dir" tag v0.1.10
    commit_version "$dir" 0.1.11
    check "VERSION 0.1.11 not yet tagged" "0.1.11-dev.$(sha_of "$dir")" "$dir"

    # A branch that left main before the release does not have its tag.
    dir="$(new_tree other-branch)"
    git_in "$dir" init -q
    commit_version "$dir" 0.1.11
    git_in "$dir" switch -q -c feature
    commit_version "$dir" ""
    local feature_sha
    feature_sha="$(sha_of "$dir")"
    git_in "$dir" switch -q -
    commit_version "$dir" ""
    git_in "$dir" tag v0.1.11
    git_in "$dir" switch -q feature
    check "v0.1.11 tagged on another branch" "0.1.11-dev.$feature_sha" "$dir"

    # A tree with no git cannot say whether VERSION was released.
    dir="$(new_tree no-git)"
    printf '0.1.10\n' >"$dir/VERSION"
    check "no git" "0.1.10-dev" "$dir"
    check "no git, release build" "0.1.10" "$dir" 1

    # A tree with no VERSION claims no release.
    dir="$(new_tree no-version)"
    git_in "$dir" init -q
    commit_version "$dir" ""
    check "no VERSION" "0.0.0-dev.$(sha_of "$dir")" "$dir"
    check "no VERSION, release build" "(failed)" "$dir" 1

    [ "$failures" -eq 0 ]
}

case "${1-}" in
    --self-test) self_test; exit ;;
    "") ;;
    *) echo "usage: scripts/app-version.sh [--self-test]" >&2; exit 2 ;;
esac

VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION" 2>/dev/null || true)"

# A source copy with no history, or a machine with no git, still has to build.
# It gets build number 1 and a short version with no sha. A shallow clone counts
# what it has, which is why both workflows check out at full depth.
COMMIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || true)"
SHA="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || true)"
COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)"

BUILD_NUMBER="${PIPIT_BUILD_NUMBER:-${COMMIT_COUNT:-1}}"

if [ "${PIPIT_RELEASE:-}" = "1" ]; then
    if [ -z "$VERSION" ]; then
        echo "a release build needs $REPO_ROOT/VERSION" >&2
        exit 1
    fi
    SHORT_VERSION="$VERSION"
elif [ -z "$VERSION" ]; then
    SHORT_VERSION="0.0.0-dev${SHA:+.$SHA}"
elif [ -z "$SHA" ]; then
    SHORT_VERSION="$VERSION-dev"
else
    TAGGED="$(git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/v$VERSION^{commit}" 2>/dev/null || true)"
    if [ -n "$TAGGED" ] && [ "$TAGGED" = "$COMMIT" ]; then
        SHORT_VERSION="$VERSION"
    elif [ -n "$TAGGED" ] && git -C "$REPO_ROOT" merge-base --is-ancestor "$TAGGED" HEAD 2>/dev/null; then
        if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "VERSION must be MAJOR.MINOR.PATCH, got: $VERSION" >&2
            exit 1
        fi
        SHORT_VERSION="${VERSION%.*}.$((${VERSION##*.} + 1))-dev.$SHA"
    else
        SHORT_VERSION="$VERSION-dev.$SHA"
    fi
fi

printf '%s\n%s\n%s\n' "$SHORT_VERSION" "$BUILD_NUMBER" "${COMMIT:-unknown}"
