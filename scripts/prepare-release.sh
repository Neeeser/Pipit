#!/bin/bash
# Open the release pull request. Usage: scripts/prepare-release.sh <patch|minor|major|X.Y.Z>
#
# Run it on an up-to-date main. It creates the branch release/<version>, writes
# the version into the tree with scripts/bump-version.sh --apply, and adds a
# "## <version>" section to the top of CHANGELOG.md. The section starts as a
# draft made from the titles of the pull requests merged since the last tag,
# grouped by label. Rewrite it in the pull request for the person updating
# Pipit before merging. Once the merge passes CI, the release workflow builds,
# tags and drafts the release. See docs/RELEASING.md.
#
# It runs under your own gh login rather than in Actions, because a pull
# request opened with the workflow token starts no checks, and main requires
# them. It needs gh and xcodegen on the PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

ARG="${1:-}"
if [ -z "$ARG" ]; then
    echo "usage: scripts/prepare-release.sh <patch|minor|major|X.Y.Z>" >&2
    exit 2
fi
for tool in gh xcodegen; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is not on the PATH" >&2
        exit 1
    fi
done
if [ -n "$(git status --porcelain)" ]; then
    echo "the working tree has uncommitted changes" >&2
    exit 1
fi

git fetch --quiet --tags origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "check out main at origin/main first (git switch main && git pull --ff-only)" >&2
    exit 1
fi

case "$ARG" in
    patch | minor | major) VERSION="$(./scripts/bump-version.sh "$ARG")" ;;
    *) VERSION="$ARG" ;;
esac
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "version must be MAJOR.MINOR.PATCH, got: $VERSION" >&2
    exit 1
fi
TAG="v$VERSION"
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
    echo "$TAG already exists" >&2
    exit 1
fi
if grep -qx "## $VERSION" CHANGELOG.md; then
    echo "CHANGELOG.md already has a section for $VERSION" >&2
    exit 1
fi
PREVIOUS="$(git tag --list 'v*.*.*' --sort=-v:refname | head -1)"
BRANCH="release/$VERSION"

# GitHub's generated notes for the range, turned into a starting draft: the
# category headings renamed for the update window, the "by @user in <link>"
# trailers and the New Contributors list dropped. The release page still
# carries all of that, because GitHub appends its own list to the release.
REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
GENERATED_ARGS=(-f "tag_name=$TAG" -f "target_commitish=main")
if [ -n "$PREVIOUS" ]; then
    GENERATED_ARGS+=(-f "previous_tag_name=$PREVIOUS")
fi
GENERATED="$(gh api "repos/$REPO/releases/generate-notes" "${GENERATED_ARGS[@]}" --jq .body)"
DRAFT="$(printf '%s\n' "$GENERATED" | awk '
    /^## New Contributors/ { skipping = 1; next }
    /^#/ { skipping = 0 }
    skipping { next }
    /^## What.s Changed/ || /^<!--/ || /^\*\*Full Changelog\*\*/ || /^[[:space:]]*$/ { next }
    /^### Features/ { print ""; print "### New"; next }
    /^### Bug fixes/ { print ""; print "### Fixes"; next }
    /^### / { print ""; print; next }
    /^[*-] / {
        line = substr($0, 3)
        sub(/ by @[^ ]+ in https?:[^ ]+$/, "", line)
        sub(/ in https?:[^ ]+$/, "", line)
        print "- " line
    }
')"

SECTION="$(printf '## %s\n\n%s\n%s\n' "$VERSION" \
    "<!-- One or two lines on what this release is, then rewrite the items below for the person updating. Cut fixes to things that were never released. -->" \
    "$DRAFT")"

git switch --quiet -c "$BRANCH"
./scripts/bump-version.sh --apply "$VERSION"

# The new section goes above the newest one, or at the end of a changelog that
# has none yet.
SECTION="$SECTION" awk '
    !done && /^## / { print ENVIRON["SECTION"]; print ""; done = 1 }
    { print }
    END { if (!done) { print ""; print ENVIRON["SECTION"] } }
' CHANGELOG.md >CHANGELOG.md.new
mv CHANGELOG.md.new CHANGELOG.md

git add VERSION project.yml Pipit.xcodeproj CHANGELOG.md
git commit --quiet -m "Release $VERSION"
git push --quiet -u origin "$BRANCH"
gh pr create --title "Release $VERSION" --label chore --body "Raises the version to $VERSION and adds its notes to CHANGELOG.md. Merging this releases it: once CI passes on main, the release workflow builds, tags $TAG and drafts the GitHub release."

echo
echo "Edit the $VERSION section of CHANGELOG.md on $BRANCH, then merge the pull request."
