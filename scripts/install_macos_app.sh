#!/usr/bin/env bash
# Install Shannon Pill on this Mac without requiring a GitHub release / cask asset.
#
# Builds Shannon.app (SwiftPM or Xcode), ad-hoc signs it, and installs to
# /Applications. This is the supported path until a signed/notarized DMG is
# published for `brew install --cask shannon-pill`.
#
# Usage:
#   ./scripts/install_macos_app.sh
#   ./scripts/install_macos_app.sh 0.1.0
#   CODESIGN_IDENTITY="Developer ID Application: …" ./scripts/install_macos_app.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${REPO_ROOT}/scripts/package_pill.sh" ${1:+"$1"} --install
