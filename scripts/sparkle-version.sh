#!/bin/bash
# The Sparkle release the scripts download their tools from.
#
# Sourced by scripts/make-appcast.sh and scripts/test-update.sh. Sparkle 2.9.6
# is the version Package.swift pins. The hash covers the release archive that
# carries generate_appcast, generate_keys and sign_update.
SPARKLE_VERSION="2.9.6"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
