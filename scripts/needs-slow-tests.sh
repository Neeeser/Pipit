#!/bin/bash
# Reads the paths a pull request changes, one per line, on standard input and
# prints `true` when the slow suites should run for it, `false` when they
# cannot be affected.
#
# The slow suites (see scripts/slow-suites.sh) run the echo canceller and the
# processing pipeline. A change is skipped only when every path in it is on the
# list below of code and files those suites do not use. A path the list does
# not know runs them, so a new module or directory errs toward the full run.
# A test file runs them when it holds a `.slow` suite; a deleted file cannot be
# read and runs them too.
#
# Usage: git diff --name-only <base>...HEAD | scripts/needs-slow-tests.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Paths that never reach a slow suite. Sources/PipitUI and the other front
# ends depend on the pipeline; nothing the slow suites import depends on them.
unrelated='^(docs|extension|App|Assets|Benchmarks|skills|\.claude)/'
unrelated+='|\.md$|^(LICENSE|VERSION|project\.yml)$|^Pipit\.xcodeproj/'
unrelated+='|^Sources/(PipitUI|PipitApp|PipitCLI|PipitCLIKit|PipitNativeHost|PipitSafariExtension|PipitEval|PipitBench)/'
unrelated+='|^\.github/workflows/(pr-labels|release|appcast)\.yml$'
# Scripts are release and packaging tools, except the ones that run the tests.
unrelated+='|^scripts/'
runs_tests='^scripts/(test|spm-env|slow-suites|needs-slow-tests)\.sh$'

while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [[ "$path" =~ $runs_tests ]]; then
        echo true
        exit 0
    fi
    if [[ "$path" =~ ^Tests/PipitTests/ && ! "$path" =~ ^Tests/PipitTests/Support/ ]]; then
        if [ ! -f "$path" ] || grep -Eq '^[[:space:]]*@Suite\(.*\.slow' "$path"; then
            echo true
            exit 0
        fi
        continue
    fi
    if [[ "$path" =~ $unrelated ]]; then
        continue
    fi
    echo true
    exit 0
done
echo false
