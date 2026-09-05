#!/bin/bash
# Canonical test run. Usage: scripts/test.sh [--filter Substring] [--list]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"
cd "$REPO_ROOT"
# The suite runs serially. Several tests share temporary directories and
# process-wide state.
# `--list` prints the test names. swift test spells it as the `list`
# subcommand, which takes no run options.
if [[ " $* " == *" --list "* ]]; then
    swift test list "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}"
else
    swift test --no-parallel "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" "$@"
fi
