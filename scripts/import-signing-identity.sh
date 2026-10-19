#!/bin/bash
# Imports the GitHub Actions signing certificate into a disposable keychain.
# The calling workflow removes build.keychain in an always-run cleanup step.
set -euo pipefail

: "${CERTIFICATE_P12:?CERTIFICATE_P12 is required}"
: "${CERTIFICATE_PASSWORD:?CERTIFICATE_PASSWORD is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

KEYCHAIN=build.keychain
CERTIFICATE_PATH="$PWD/certificate.p12"
trap 'rm -f "$CERTIFICATE_PATH"' EXIT
security create-keychain -p actions "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security unlock-keychain -p actions "$KEYCHAIN"
# Builds can outlast the keychain's idle timeout. CI cannot answer an unlock prompt.
security set-keychain-settings "$KEYCHAIN"
printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$CERTIFICATE_PATH"
security import "$CERTIFICATE_PATH" -k "$KEYCHAIN" -P "$CERTIFICATE_PASSWORD" \
    -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k actions "$KEYCHAIN"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [ -z "$IDENTITY" ]; then
    echo "certificate imported but no Developer ID Application identity found" >&2
    exit 1
fi
echo "::add-mask::$IDENTITY"
echo "identity=$IDENTITY" >> "$GITHUB_OUTPUT"
echo "signed=true" >> "$GITHUB_OUTPUT"
