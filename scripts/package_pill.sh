#!/usr/bin/env bash
# Package Shannon Pill into a distributable DMG for Homebrew (cask shannon-pill).
#
# Usage:
#   ./scripts/package_pill.sh                 # version from VERSION / Pill Info / 0.1.0
#   ./scripts/package_pill.sh 1.2.3           # explicit version
#   ./scripts/package_pill.sh --install       # build + install to /Applications
#   ./scripts/package_pill.sh --update-cask   # build + write sha256 into Casks/shannon-pill.rb
#   ./scripts/package_pill.sh 1.2.3 --install --update-cask
#
# Environment:
#   CODESIGN_IDENTITY   Developer ID Application: …  (default: ad-hoc "-")
#   NOTARY_PROFILE      notarytool keychain profile (optional notarization)
#   SHANNON_DMG_DIR     output directory (default: <repo>/dist)
#   SHANNON_BUILD_METHOD  auto|swiftpm|xcode  (default: auto)
#
# Produces Shannon-<version>.dmg containing Shannon.app.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Args
# ---------------------------------------------------------------------------
VERSION_ARG=""
DO_INSTALL=0
DO_UPDATE_CASK=0
for arg in "$@"; do
  case "${arg}" in
    --install) DO_INSTALL=1 ;;
    --update-cask) DO_UPDATE_CASK=1 ;;
    --help|-h)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    -*)
      echo "error: unknown option: ${arg}" >&2
      exit 2
      ;;
    *)
      if [[ -n "${VERSION_ARG}" ]]; then
        echo "error: unexpected argument: ${arg}" >&2
        exit 2
      fi
      VERSION_ARG="${arg}"
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Resolve paths / version
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PILL_DIR="${REPO_ROOT}/Pill"
DIST_DIR="${SHANNON_DMG_DIR:-${REPO_ROOT}/dist}"
BUILD_METHOD="${SHANNON_BUILD_METHOD:-auto}"
WORKDIR="${TMPDIR:-/tmp}/shannon-pill-package.$$"
trap 'rm -rf "${WORKDIR}"' EXIT

if [[ -n "${VERSION_ARG}" ]]; then
  VERSION="${VERSION_ARG}"
elif [[ -f "${REPO_ROOT}/VERSION" ]]; then
  VERSION="$(tr -d '[:space:]' < "${REPO_ROOT}/VERSION")"
elif [[ -f "${PILL_DIR}/Resources/Info.plist" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "${PILL_DIR}/Resources/Info.plist" 2>/dev/null || true)"
fi
VERSION="${VERSION:-0.1.0}"

if [[ ! "${VERSION}" =~ ^[0-9]+(\.[0-9]+){1,3}([.-][A-Za-z0-9.]+)?$ ]]; then
  echo "error: invalid version '${VERSION}'" >&2
  exit 1
fi

echo "==> Packaging Shannon Pill ${VERSION}"
echo "    repo:   ${REPO_ROOT}"
echo "    method: ${BUILD_METHOD}"
echo "    dist:   ${DIST_DIR}"

mkdir -p "${DIST_DIR}" "${WORKDIR}"
APP_DIR="${WORKDIR}/Shannon.app"
DMG="${DIST_DIR}/Shannon-${VERSION}.dmg"
IDENTITY="${CODESIGN_IDENTITY:--}"

# ---------------------------------------------------------------------------
# 2. Tool checks
# ---------------------------------------------------------------------------
need() {
  if ! command -v "$1" &>/dev/null; then
    echo "error: required tool not found: $1" >&2
    echo "       Install developer deps with: brew bundle install" >&2
    exit 1
  fi
}

need hdiutil
need shasum
need codesign
need ditto

if ! xcode-select -p &>/dev/null; then
  echo "error: Xcode CLT / Xcode required (xcode-select -p failed)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Build Shannon.app
# ---------------------------------------------------------------------------
build_via_swiftpm() {
  need swift
  echo "==> Building via SwiftPM (Pill/Scripts/make_app.sh release)"
  (
    cd "${PILL_DIR}"
    ./Scripts/make_app.sh release
  )
  local src="${PILL_DIR}/build/ShannonPill.app"
  if [[ ! -d "${src}" ]]; then
    echo "error: SwiftPM build did not produce ${src}" >&2
    return 1
  fi
  rm -rf "${APP_DIR}"
  ditto "${src}" "${APP_DIR}"
}

build_via_xcode() {
  need xcodegen
  need xcodebuild
  echo "==> Building via XcodeGen + xcodebuild archive"
  (
    cd "${PILL_DIR}"
    xcodegen generate --spec project.yml
  )
  local archive="${WORKDIR}/Shannon.xcarchive"
  rm -rf "${archive}"
  xcodebuild archive \
    -project "${PILL_DIR}/ShannonPill.xcodeproj" \
    -scheme ShannonPill \
    -archivePath "${archive}" \
    -destination "generic/platform=macOS" \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    CODE_SIGNING_ALLOWED=NO \
    ONLY_ACTIVE_ARCH=NO \
    | tail -n 40

  local app_in_archive="${archive}/Products/Applications/ShannonPill.app"
  if [[ ! -d "${app_in_archive}" ]]; then
    echo "error: expected app at ${app_in_archive}" >&2
    return 1
  fi
  rm -rf "${APP_DIR}"
  ditto "${app_in_archive}" "${APP_DIR}"
}

case "${BUILD_METHOD}" in
  swiftpm) build_via_swiftpm ;;
  xcode)   build_via_xcode ;;
  auto)
    if build_via_xcode 2>"${WORKDIR}/xcode.err"; then
      :
    else
      echo "==> Xcode archive failed; falling back to SwiftPM"
      cat "${WORKDIR}/xcode.err" >&2 || true
      build_via_swiftpm
    fi
    ;;
  *)
    echo "error: unknown SHANNON_BUILD_METHOD=${BUILD_METHOD}" >&2
    exit 1
    ;;
esac

if [[ ! -d "${APP_DIR}/Contents/MacOS" ]]; then
  echo "error: incomplete app bundle at ${APP_DIR}" >&2
  exit 1
fi

# Align marketing version in the bundled Info.plist when present.
if [[ -f "${APP_DIR}/Contents/Info.plist" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" \
    "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" \
    "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Codesign
# ---------------------------------------------------------------------------
echo "==> Codesigning Shannon.app (identity: ${IDENTITY})"
# Deep sign nested frameworks first, then the bundle.
if [[ "${IDENTITY}" == "-" ]]; then
  codesign --force --deep --sign - --timestamp=none "${APP_DIR}"
else
  codesign --force --deep --options runtime --timestamp --sign "${IDENTITY}" "${APP_DIR}"
fi

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}" 2>&1 | tail -n 20
# spctl may fail for ad-hoc; warn only
if ! spctl --assess --type execute --verbose "${APP_DIR}" 2>&1; then
  if [[ "${IDENTITY}" == "-" ]]; then
    echo "    note: spctl assess failed (expected for ad-hoc). Users may need to clear quarantine."
  else
    echo "warning: spctl assess failed — check Developer ID / hardened runtime entitlements" >&2
  fi
fi

# Bundle sanity: LSUIElement
if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "${APP_DIR}/Contents/Info.plist" 2>/dev/null | grep -qi true; then
  echo "    LSUIElement=true (agent UI, no Dock icon)"
else
  echo "warning: LSUIElement not true — app may show a Dock icon" >&2
fi

# ---------------------------------------------------------------------------
# 5. DMG
# ---------------------------------------------------------------------------
# Prefer a reproducible ZIP for the Homebrew cask (stable sha256 across CI).
# Also emit a UDZO DMG for human drag-install distribution.
ZIP="${DIST_DIR}/Shannon-${VERSION}.zip"
STAGE="${WORKDIR}/stage"
rm -rf "${STAGE}"
mkdir -p "${STAGE}"
ditto "${APP_DIR}" "${STAGE}/Shannon.app"

echo "==> Creating reproducible ZIP ${ZIP}"
rm -f "${ZIP}"
# Normalize mtimes so shasum is stable for the same binary contents.
find "${STAGE}" -exec touch -t 202401010000 {} +
# -X: no extra fields; -y: store symlinks as links; -r: recursive
(
  cd "${STAGE}"
  zip -X -y -r -q "${ZIP}" Shannon.app
)

echo "==> Creating DMG ${DMG}"
rm -f "${DMG}"
ln -sf /Applications "${STAGE}/Applications"
# hdiutil remains the portable path; Apple may warn about deprecation on newer macOS.
hdiutil create \
  -volname "Shannon ${VERSION}" \
  -srcfolder "${STAGE}" \
  -ov \
  -format UDZO \
  "${DMG}" >/dev/null

# Optional notarization for Developer ID builds (staple the DMG; zip is the cask asset).
if [[ "${IDENTITY}" != "-" && -n "${NOTARY_PROFILE:-}" ]]; then
  need xcrun
  echo "==> Notarizing DMG with profile ${NOTARY_PROFILE}"
  xcrun notarytool submit "${DMG}" --keychain-profile "${NOTARY_PROFILE}" --wait
  xcrun stapler staple "${DMG}"
  # Notarize the zip as well (cask download).
  xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait || true
  echo "    Notarization complete"
fi

ZIP_SHA="$(shasum -a 256 "${ZIP}" | awk '{print $1}')"
DMG_SHA="$(shasum -a 256 "${DMG}" | awk '{print $1}')"
ZIP_SIZE="$(du -h "${ZIP}" | awk '{print $1}')"
DMG_SIZE="$(du -h "${DMG}" | awk '{print $1}')"
# Cask consumes the ZIP (reproducible).
SHA256="${ZIP_SHA}"

echo
echo "==> Artifacts ready"
echo "    zip:    ${ZIP}  (${ZIP_SIZE})"
echo "    zip sha256: ${ZIP_SHA}"
echo "    dmg:    ${DMG}  (${DMG_SIZE})"
echo "    dmg sha256: ${DMG_SHA}"

# ---------------------------------------------------------------------------
# 6. Update cask (optional)
# ---------------------------------------------------------------------------
if [[ "${DO_UPDATE_CASK}" -eq 1 ]]; then
  CASK="${REPO_ROOT}/Casks/shannon-pill.rb"
  if [[ ! -f "${CASK}" ]]; then
    echo "error: cask not found at ${CASK}" >&2
    exit 1
  fi
  echo "==> Updating ${CASK} version + sha256"
  # Portable in-place edit without relying on GNU sed
  python3 - "${CASK}" "${VERSION}" "${SHA256}" <<'PY'
import pathlib, re, sys
path, version, sha = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
text2, n1 = re.subn(r'(version\s+")[^"]+(")', rf'\g<1>{version}\2', text, count=1)
text3, n2 = re.subn(
    r'(sha256\s+")[0-9a-fA-F]{64}(")',
    rf'\g<1>{sha}\2',
    text2,
    count=1,
)
if n1 != 1 or n2 != 1:
    sys.exit(f"failed to patch cask (version={n1}, sha256={n2})")
path.write_text(text3)
print(f"    version {version}")
print(f"    sha256  {sha}")
PY
fi

# ---------------------------------------------------------------------------
# 7. Local install (optional)
# ---------------------------------------------------------------------------
if [[ "${DO_INSTALL}" -eq 1 ]]; then
  DEST="/Applications/Shannon.app"
  echo "==> Installing to ${DEST}"
  # Prefer ditto for resource-fork / quarantine-safe copy
  rm -rf "${DEST}"
  ditto "${APP_DIR}" "${DEST}"
  # Drop quarantine so local builds launch without Gatekeeper theatre
  xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
  if [[ "${IDENTITY}" == "-" ]]; then
    codesign --force --deep --sign - --timestamp=none "${DEST}" 2>/dev/null || true
  fi
  echo "    Installed. Launch with:  open ${DEST}"
  echo "    Or day-to-day:           ./scripts/shannon start|stop|status"
  echo "    Stop with:               pkill -x ShannonPill"
fi

# ---------------------------------------------------------------------------
# 8. Next steps
# ---------------------------------------------------------------------------
echo
echo "==> Next steps"
echo "    1. Publish release assets (cask uses the ZIP):"
echo "         gh release create v${VERSION} \"${ZIP}\" \"${DMG}\" --title \"Shannon v${VERSION}\" --generate-notes"
echo "    2. Point the cask at the release (if not already --update-cask):"
echo "         ./scripts/package_pill.sh ${VERSION} --update-cask"
echo "    3. Trust + install from the monorepo tap:"
echo "         brew tap lebonhommepharma/shannon https://github.com/LeBonhommePharma/Shannon"
echo "         brew trust --cask lebonhommepharma/shannon/shannon-pill"
echo "         brew install --cask lebonhommepharma/shannon/shannon-pill"
echo "    4. Local-only (no GitHub release):"
echo "         ./scripts/package_pill.sh --install"
echo "         # or: ./scripts/install_macos_app.sh"
