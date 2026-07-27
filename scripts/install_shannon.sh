#!/usr/bin/env bash
# install_shannon.sh — pure-Python install / update (Linux / macOS).
#
# PRIMARY (from a local GitHub clone — easy update = git pull + re-run):
#   ./scripts/install_shannon.sh --path
#   ./scripts/install_shannon.sh --path --update   # same action; documents update
#
# Other modes:
#   ./scripts/install_shannon.sh                  # PyPI shannon-entropy
#   ./scripts/install_shannon.sh --git            # git+https://github.com/…/Shannon.git
#   ./scripts/install_shannon.sh --source 'git+https://…'
#   ./scripts/install_shannon.sh --path --venv    # create .venv-install first
#   ./scripts/install_shannon.sh --path --skip-tests
#
# Always sets SHANNON_SKIP_CORE=1. Delegates to scripts/shannon_installer.py.
# Windows: use scripts/Install-Shannon.ps1 (same modes).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="pypi"
USE_VENV=0
SKIP_TESTS=0
UPDATE=0
EXTRA_SOURCE=""

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path|-e|--editable)
      SOURCE="path"
      shift
      ;;
    --pypi|--release)
      SOURCE="pypi"
      shift
      ;;
    --git|--github|--head)
      SOURCE="git"
      shift
      ;;
    --source)
      shift
      [[ $# -gt 0 ]] || { echo "error: --source needs a value" >&2; exit 2; }
      EXTRA_SOURCE="$1"
      SOURCE="$1"
      shift
      ;;
    --update|--upgrade)
      UPDATE=1
      # Default source for update when still on pypi and we have a clone: path.
      if [[ "${SOURCE}" == "pypi" && -f "${REPO}/pyproject.toml" ]]; then
        SOURCE="path"
      fi
      shift
      ;;
    --venv)
      USE_VENV=1
      shift
      ;;
    --skip-tests)
      SKIP_TESTS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# If user passed --source, honour it (wins over --path/--git flags ordered before).
if [[ -n "${EXTRA_SOURCE}" ]]; then
  SOURCE="${EXTRA_SOURCE}"
fi

info() { printf '→ %s\n' "$*"; }
die()  { printf '✗ %s\n' "$*" >&2; exit 1; }

PY="${PYTHON:-}"
if [[ -z "${PY}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PY=python3
  elif command -v python >/dev/null 2>&1; then
    PY=python
  else
    die "python3 not found"
  fi
fi

# Venv creation is handled by shannon_installer.py (auto on PEP 668, or --venv).

ARGS=( "${REPO}/scripts/shannon_installer.py" --source "${SOURCE}" --python "${PY}" )
if [[ "${SKIP_TESTS}" -eq 1 ]]; then
  ARGS+=( --skip-tests )
fi
if [[ "${UPDATE}" -eq 1 ]]; then
  ARGS+=( --update )
fi
if [[ "${USE_VENV}" -eq 1 ]]; then
  # Force venv; installer also auto-venvs on PEP 668 system Pythons.
  ARGS+=( --venv )
fi

exec "${PY}" "${ARGS[@]}"
