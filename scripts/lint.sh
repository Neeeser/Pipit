#!/bin/bash
# Check style without changing files. Usage: scripts/lint.sh
#
# It reads the same `.swift-format` and the same paths as scripts/format.sh.
# A finding exits non-zero, so CI fails on code that has not been run through
# scripts/format.sh.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PIPIT_LINT_PATHS=(Sources/Pipit* Tests Package.swift)

swift format lint --strict --recursive --parallel "${PIPIT_LINT_PATHS[@]}"

# SwiftLint runs here once .swiftlint.yml exists.
