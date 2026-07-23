#!/usr/bin/env bash
# Local install helper — delegates to the primary ./scripts/shannon path.
#
#   ./scripts/install_macos_app.sh           # install app + pets
#   ./scripts/install_macos_app.sh --launch  # full bootstrap (same as ./scripts/shannon)

set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH=0
for arg in "$@"; do
  case "${arg}" in
    --launch|-l) LAUNCH=1 ;;
    --help|-h)
      sed -n '2,6p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

if [[ "${LAUNCH}" -eq 1 ]]; then
  exec "${REPO}/scripts/shannon"
else
  exec "${REPO}/scripts/shannon" install
fi
