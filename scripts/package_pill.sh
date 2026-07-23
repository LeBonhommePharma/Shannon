#!/usr/bin/env bash
# Package ShannonPill.app into a distributable DMG for Homebrew distribution.
#
# Usage:
#   ./scripts/package_pill.sh          # version from VERSION file or 0.1.0
#   ./scripts/package_pill.sh 1.2.3    # explicit version
#
# Produces an UNSIGNED DMG suitable for local testing.
# Production releases require LP's Developer ID Application certificate.
# After signing, upload the DMG to GitHub releases and update
# Casks/shannon-pill.rb with the real url and sha256.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Check required tools
# ---------------------------------------------------------------------------
REQUIRED_TOOLS=(xcodegen xcodebuild hdiutil shasum)
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "error: required tool not found: ${tool}" >&2
        echo "       Install with: brew bundle install" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 2. Resolve version
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -n "${1:-}" ]]; then
    VERSION="$1"
elif [[ -f "${REPO_ROOT}/VERSION" ]]; then
    VERSION="$(< "${REPO_ROOT}/VERSION")"
else
    VERSION="0.1.0"
fi

echo "==> Packaging ShannonPill version ${VERSION}"

ARCHIVE="/tmp/Shannon.xcarchive"
APP_DIR="/tmp/Shannon.app"
DMG="/tmp/Shannon-${VERSION}.dmg"

# ---------------------------------------------------------------------------
# 3. Generate Xcode project from project.yml
# ---------------------------------------------------------------------------
echo "==> Generating Xcode project"
(cd "${REPO_ROOT}/Pill" && xcodegen generate)

# ---------------------------------------------------------------------------
# 4. Archive (unsigned — production requires LP's Developer ID cert)
# ---------------------------------------------------------------------------
echo "==> Archiving ShannonPill (unsigned, CODE_SIGNING_ALLOWED=NO)"
xcodebuild archive \
    -project "${REPO_ROOT}/Pill/ShannonPill.xcodeproj" \
    -scheme ShannonPill \
    -archivePath "${ARCHIVE}" \
    CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="${VERSION}"

# ---------------------------------------------------------------------------
# 5. Export Shannon.app from the archive
# ---------------------------------------------------------------------------
echo "==> Exporting Shannon.app from archive"
rm -rf "${APP_DIR}"

APP_IN_ARCHIVE="${ARCHIVE}/Products/Applications/ShannonPill.app"
if [[ ! -d "${APP_IN_ARCHIVE}" ]]; then
    echo "error: expected app bundle at ${APP_IN_ARCHIVE}" >&2
    echo "       The archive may not have built correctly." >&2
    exit 1
fi

# Copy and rename to Shannon.app so the cask stanza matches.
cp -R "${APP_IN_ARCHIVE}" "${APP_DIR}"
echo "    Exported to ${APP_DIR}"

# ---------------------------------------------------------------------------
# 6. Create DMG
# ---------------------------------------------------------------------------
echo "==> Creating ${DMG}"
rm -f "${DMG}"
hdiutil create \
    -volname Shannon \
    -srcfolder "${APP_DIR}" \
    -ov \
    -format UDZO \
    "${DMG}"

# ---------------------------------------------------------------------------
# 7. Print SHA256 for the cask
# ---------------------------------------------------------------------------
echo
echo "==> SHA256 (paste into Casks/shannon-pill.rb sha256 field):"
shasum -a 256 "${DMG}"

# ---------------------------------------------------------------------------
# 8. Next steps
# ---------------------------------------------------------------------------
DMG_NAME="Shannon-${VERSION}.dmg"
echo
echo "==> Next steps:"
echo "    1. Upload ${DMG_NAME} to GitHub releases:"
echo "         gh release create v${VERSION} \"${DMG}\" --title \"Shannon v${VERSION}\""
echo "    2. Update Casks/shannon-pill.rb with the URL and SHA256 above"
echo "    3. Verify locally before pushing the cask:"
echo "         brew install --cask --no-quarantine ./Casks/shannon-pill.rb"
