#!/usr/bin/env bash
# After tagging vX.Y.Z, compute artifact checksums and print the Formula/Cask edits.
#
# Usage:
#   ./scripts/update_homebrew_artifacts.sh v2.0.0
#   ./scripts/update_homebrew_artifacts.sh 2.0.0 --apply   # patch Formula + download DMG sha if present
#
# Requires network access to GitHub for the source tarball.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0
TAG=""

for arg in "$@"; do
  case "${arg}" in
    --apply) APPLY=1 ;;
    --help|-h)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    -*)
      echo "error: unknown option ${arg}" >&2
      exit 2
      ;;
    *) TAG="${arg}" ;;
  esac
done

if [[ -z "${TAG}" ]]; then
  echo "usage: $0 vX.Y.Z [--apply]" >&2
  exit 2
fi

TAG="${TAG#v}"
VERSION="${TAG}"
TARBALL_URL="https://github.com/LeBonhommePharma/Shannon/archive/refs/tags/v${VERSION}.tar.gz"
ZIP_URL="https://github.com/LeBonhommePharma/Shannon/releases/download/v${VERSION}/Shannon-${VERSION}.zip"
DMG_URL="https://github.com/LeBonhommePharma/Shannon/releases/download/v${VERSION}/Shannon-${VERSION}.dmg"

WORKDIR="${TMPDIR:-/tmp}/shannon-hb-artifacts.$$"
mkdir -p "${WORKDIR}"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "==> Fetching source tarball"
if ! curl -fsSL -o "${WORKDIR}/src.tar.gz" "${TARBALL_URL}"; then
  echo "error: could not download ${TARBALL_URL}" >&2
  echo "       Create and push tag v${VERSION} first." >&2
  exit 1
fi
SRC_SHA="$(shasum -a 256 "${WORKDIR}/src.tar.gz" | awk '{print $1}')"
echo "    tarball sha256: ${SRC_SHA}"

ZIP_SHA=""
if curl -fsSL -o "${WORKDIR}/Shannon.zip" "${ZIP_URL}" 2>/dev/null; then
  ZIP_SHA="$(shasum -a 256 "${WORKDIR}/Shannon.zip" | awk '{print $1}')"
  echo "    zip sha256:     ${ZIP_SHA}"
else
  echo "    zip: not published yet at ${ZIP_URL}"
fi

DMG_SHA=""
if curl -fsSL -o "${WORKDIR}/Shannon.dmg" "${DMG_URL}" 2>/dev/null; then
  DMG_SHA="$(shasum -a 256 "${WORKDIR}/Shannon.dmg" | awk '{print $1}')"
  echo "    dmg sha256:     ${DMG_SHA}"
else
  echo "    dmg: not published yet at ${DMG_URL}"
fi

if [[ "${APPLY}" -eq 1 ]]; then
  FORMULA="${REPO_ROOT}/Formula/shannon.rb"
  python3 - "${FORMULA}" "${VERSION}" "${SRC_SHA}" <<'PY'
import pathlib, re, sys
path, version, sha = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
block = f'''  url "https://github.com/LeBonhommePharma/Shannon/archive/refs/tags/v{version}.tar.gz"
  sha256 "{sha}"
  version "{version}"

'''
# Insert stable url after license if not present; replace if present.
if re.search(r'^\s*url\s+"https://github.com/LeBonhommePharma/Shannon/archive', text, re.M):
    text = re.sub(
        r'^\s*url\s+"https://github.com/LeBonhommePharma/Shannon/archive[^"]+"\n\s*sha256\s+"[^"]+"\n\s*version\s+"[^"]+"\n',
        block,
        text,
        count=1,
        flags=re.M,
    )
else:
    text = re.sub(
        r'(license\s+"Apache-2.0"\n)',
        rf'\1\n{block}',
        text,
        count=1,
    )
    # Drop the "uncomment after tagging" comment block if present
    text = re.sub(
        r'\n  # Stable installs require a tagged GitHub release.*?\n  # version "2.0.0"\n',
        '\n',
        text,
        count=1,
        flags=re.S,
    )
path.write_text(text)
print(f"updated {path}")
PY

  if [[ -n "${ZIP_SHA}" ]]; then
    CASK="${REPO_ROOT}/Casks/shannon-pill.rb"
    python3 - "${CASK}" "${VERSION}" "${ZIP_SHA}" <<'PY'
import pathlib, re, sys
path, version, sha = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
text, n1 = re.subn(r'(version\s+")[^"]+(")', rf'\g<1>{version}\2', text, count=1)
text, n2 = re.subn(r'(sha256\s+")[0-9a-fA-F]{64}(")', rf'\g<1>{sha}\2', text, count=1)
if n1 != 1 or n2 != 1:
    raise SystemExit(f"cask patch failed version={n1} sha={n2}")
path.write_text(text)
print(f"updated {path}")
PY
  fi
else
  cat <<EOF

# Manual Formula/shannon.rb stable stanza:
  url "https://github.com/LeBonhommePharma/Shannon/archive/refs/tags/v${VERSION}.tar.gz"
  sha256 "${SRC_SHA}"
  version "${VERSION}"

EOF
  if [[ -n "${ZIP_SHA}" ]]; then
    cat <<EOF
# Manual Casks/shannon-pill.rb (ZIP is the cask asset):
  version "${VERSION}"
  sha256 "${ZIP_SHA}"

EOF
  fi
  echo "Re-run with --apply to patch files in-place."
fi
