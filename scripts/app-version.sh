#!/bin/bash
# Prints the two version numbers a Pipit build stamps into its Info.plist: the
# short version on the first line, the build number on the second.
#
# scripts/bundle-app.sh and the run script phase in project.yml both read it, so
# a bundle assembled either way carries the same two numbers.
#
# The build number is the commit count. It rises with every commit, so any two
# checkouts are ordered, and Sparkle compares it to decide whether a feed item
# is newer than the running copy.
#
# The short version is what VERSION says when PIPIT_RELEASE=1 is set, which the
# release workflow does. Every other build reads <VERSION>-dev.<short sha>. A
# dirty working tree adds nothing, so the sha names the commit the build started
# from and nothing more.
#
# PIPIT_BUILD_NUMBER overrides the commit count.
#
# Usage: scripts/app-version.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

VERSION="$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "0.1.0")"

# A source copy with no history, or a machine with no git, still has to build.
# It gets build number 1 and a short version with no sha. A shallow clone counts
# what it has, which is why both workflows check out at full depth.
COMMIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || true)"
SHA="$(git -C "$REPO_ROOT" rev-parse --short=7 HEAD 2>/dev/null || true)"

BUILD_NUMBER="${PIPIT_BUILD_NUMBER:-${COMMIT_COUNT:-1}}"

if [ "${PIPIT_RELEASE:-}" = "1" ]; then
    SHORT_VERSION="$VERSION"
elif [ -n "$SHA" ]; then
    SHORT_VERSION="$VERSION-dev.$SHA"
else
    SHORT_VERSION="$VERSION-dev"
fi

printf '%s\n%s\n' "$SHORT_VERSION" "$BUILD_NUMBER"
