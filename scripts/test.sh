#!/bin/bash
# Canonical test run. Usage: scripts/test.sh [--filter Substring] [--list]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=spm-env.sh
source "$REPO_ROOT/scripts/spm-env.sh"
cd "$REPO_ROOT"
# The suite runs serially: it was written for a harness that ran one test at a
# time, and several tests share temporary directories and process-wide state.
swift test --no-parallel "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" "$@"
# The tests still on the TestKit harness. A --filter that matches nothing here
# is expected while files are being converted.
swift run --configuration debug "${PIPIT_SWIFT_FLAGS[@]+"${PIPIT_SWIFT_FLAGS[@]}"}" pipit-test "$@"
