#!/bin/bash
# Reformat the Swift sources in place. Usage: scripts/format.sh [path ...]
#
# The rules live in `.swift-format`, which is the output of
# `swift format dump-configuration` with two values changed. JSON takes no
# comments, so the deviations from the toolchain defaults are recorded here.
#
#   indentation.spaces  4    (default 2). The code is written with 4 spaces.
#   lineLength          120  (default 100). 120 keeps the long type names in
#                            PipitServices and PipitUI on one line.
#
# Everything else, including the rule set, is the toolchain default. Three
# values the review asked for are already the defaults on 6.3 and are left
# alone: `respectsExistingLineBreaks` true,
# `multiElementCollectionTrailingCommas` true, and `lineBreakBeforeEachArgument`
# false. `NoBlockComments` stays on because it reports nothing on this tree.
#
# `swift format` has no exclusion option, so the paths are listed explicitly.
# `Sources/Pipit*` names every Swift module and leaves out the vendored
# `Sources/CWebRTCAEC3`, which holds C and C++ only.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [ "$#" -gt 0 ]; then
    PIPIT_FORMAT_PATHS=("$@")
else
    PIPIT_FORMAT_PATHS=(Sources/Pipit* Tests Package.swift)
fi

swift format format --in-place --recursive --parallel "${PIPIT_FORMAT_PATHS[@]}"
