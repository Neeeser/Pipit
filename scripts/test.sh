#!/bin/bash
# Canonical test run. Usage: scripts/test.sh [--filter Substring] [--list]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"
cd "$REPO_ROOT"
# The suite runs serially. Several tests share temporary directories and
# process-wide state.
# `--list` prints the test names. It maps to `swift test --list-tests`, which
# takes the build flags but no run options, so a `--filter` is applied to the
# printed names here. That option prints a deprecation warning on this
# toolchain, which is expected.
if [[ " $* " == *" --list "* ]]; then
    PIPIT_LIST_ARGS=()
    PIPIT_LIST_PATTERN=""
    PIPIT_WANT_PATTERN=0
    for arg in "$@"; do
        if [[ "$PIPIT_WANT_PATTERN" == 1 ]]; then
            PIPIT_LIST_PATTERN="$arg"
            PIPIT_WANT_PATTERN=0
        elif [[ "$arg" == "--filter" ]]; then
            PIPIT_WANT_PATTERN=1
        elif [[ "$arg" != "--list" ]]; then
            PIPIT_LIST_ARGS+=("$arg")
        fi
    done
    if [[ -n "$PIPIT_LIST_PATTERN" ]]; then
        swift test --list-tests "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" \
            "${PIPIT_LIST_ARGS[@]+"${PIPIT_LIST_ARGS[@]}"}" | grep -E "$PIPIT_LIST_PATTERN"
    else
        swift test --list-tests "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" \
            "${PIPIT_LIST_ARGS[@]+"${PIPIT_LIST_ARGS[@]}"}"
    fi
else
    swift test --no-parallel "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" "$@"
fi
