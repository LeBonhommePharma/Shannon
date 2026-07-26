#!/usr/bin/env bash
# install_shannon.sh — cross-platform-friendly pure-Python install (Linux/macOS).
#
#   ./scripts/install_shannon.sh              # pip install shannon-entropy from PyPI
#   ./scripts/install_shannon.sh --path        # editable install from this repo
#   ./scripts/install_shannon.sh --path --venv # create .venv first
#
# Always sets SHANNON_SKIP_CORE=1 so missing compilers never fail the install.
# Windows users: use scripts/Install-Shannon.ps1 instead.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="pypi"
USE_VENV=0
SKIP_TESTS=0

for arg in "$@"; do
  case "${arg}" in
    --path) MODE="path" ;;
    --venv) USE_VENV=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "error: unknown option ${arg}" >&2
      exit 2
      ;;
  esac
done

info() { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
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

"${PY}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' \
  || die "Python 3.10+ required"

export SHANNON_SKIP_CORE=1
info "SHANNON_SKIP_CORE=1 (pure-Python install)"

if [[ "${USE_VENV}" -eq 1 ]]; then
  VENV="${REPO}/.venv-install"
  info "Creating venv at ${VENV}"
  "${PY}" -m venv "${VENV}"
  # shellcheck disable=SC1091
  source "${VENV}/bin/activate"
  PY=python
fi

info "Upgrading pip"
"${PY}" -m pip install --upgrade pip setuptools wheel

if [[ "${MODE}" == "path" ]]; then
  info "Editable install from ${REPO}"
  "${PY}" -m pip install -e "${REPO}"
else
  info "pip install shannon-entropy (PyPI)"
  "${PY}" -m pip install shannon-entropy
fi

if [[ "${SKIP_TESTS}" -eq 1 ]]; then
  ok "Install complete (tests skipped)"
  exit 0
fi

info "Smoke: import + entropy"
"${PY}" - <<'PY'
import numpy as np
import shannon
from shannon import ShannonCollapseDetector, shannon_entropy_from_probs

assert shannon.__version__, shannon.__version__
print("shannon", shannon.__version__, "_HAS_CORE=", getattr(shannon, "_HAS_CORE", None))
h = shannon_entropy_from_probs(np.array([0.25, 0.25, 0.25, 0.25], dtype=float))
assert abs(h - 2.0) < 1e-9, h
ShannonCollapseDetector()
print("entropy_smoke_ok", h)
PY

info "Smoke: shannon-monitor --help"
if command -v shannon-monitor >/dev/null 2>&1; then
  shannon-monitor --help >/dev/null
else
  "${PY}" -m shannon.cli --help >/dev/null
fi

ok "Shannon pure-Python install smoke passed"
