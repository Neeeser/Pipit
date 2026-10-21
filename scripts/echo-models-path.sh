#!/bin/bash
# Locate the audio models in a SwiftPM resource bundle. Native builds use a
# flat bundle; SwiftBuild uses the macOS Contents/Resources layout.
set -euo pipefail
bundle="$1"
for models in "$bundle/EchoModels" "$bundle/Contents/Resources/EchoModels"; do
    if [ -d "$models" ]; then
        printf '%s\n' "$models"
        exit 0
    fi
done
echo "no echo models in $bundle. Build first." >&2
exit 1
