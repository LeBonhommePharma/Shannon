# shellcheck shell=bash
# lib_shannon_ui.sh — resolve Shannon UI (ShannonUI) checkout for packaging / tests.
#
# Source from operator scripts after REPO/ROOT is set:
#   # shellcheck source=lib_shannon_ui.sh
#   source "$(dirname "${BASH_SOURCE[0]}")/lib_shannon_ui.sh"
#   if resolve_shannon_ui; then … use $SHANNON_UI_ROOT / $PILL_DIR …
#
# Resolve order:
#   1) $SHANNON_UI_ROOT (if already set and valid)
#   2) sibling ../ShannonUI
#   3) $HOME/Projects/ShannonUI
#   4) legacy in-tree Pill/ (pre-extract monorepo only)
#
# Sets (on success):
#   SHANNON_UI_ROOT  — checkout root that contains Pill/
#   PILL_DIR         — absolute path to Pill/ (with Scripts/make_app.sh)

_try_ui_root() {
  # $1 = candidate path; sets SHANNON_UI_ROOT + PILL_DIR on success.
  local c="$1" root
  [[ -n "${c}" ]] || return 1
  root="$(cd "${c}" 2>/dev/null && pwd)" || return 1
  if [[ -x "${root}/Pill/Scripts/make_app.sh" ]]; then
    SHANNON_UI_ROOT="${root}"
    PILL_DIR="${root}/Pill"
    export SHANNON_UI_ROOT PILL_DIR
    return 0
  fi
  # Candidate pointed directly at Pill/
  if [[ -x "${root}/Scripts/make_app.sh" && "$(basename "${root}")" == "Pill" ]]; then
    PILL_DIR="${root}"
    SHANNON_UI_ROOT="$(cd "${root}/.." && pwd)"
    export SHANNON_UI_ROOT PILL_DIR
    return 0
  fi
  return 1
}

resolve_shannon_ui() {
  local candidates=()
  local c
  local cli_root="${REPO:-${ROOT:-}}"

  # Explicit SHANNON_UI_ROOT is sticky: if set, only that path is tried (no silent fallback).
  if [[ -n "${SHANNON_UI_ROOT:-}" ]]; then
    if _try_ui_root "${SHANNON_UI_ROOT}"; then
      return 0
    fi
    return 1
  fi

  if [[ -n "${cli_root}" ]]; then
    candidates+=(
      "${cli_root}/../ShannonUI"
    )
  fi
  candidates+=(
    "${HOME}/Projects/ShannonUI"
  )
  if [[ -n "${cli_root}" ]]; then
    # Legacy monorepo layout (Pill still under this repo).
    candidates+=("${cli_root}")
  fi

  for c in "${candidates[@]}"; do
    if _try_ui_root "${c}"; then
      return 0
    fi
  done
  return 1
}

shannon_ui_missing_msg() {
  cat <<'EOF'
Shannon UI source not found (extracted to LeBonhommePharma/ShannonUI).
  Clone:  git clone https://github.com/LeBonhommePharma/ShannonUI ../ShannonUI
  Or set: export SHANNON_UI_ROOT=/path/to/ShannonUI
  Docs:   docs/SHANNON_UI.md
EOF
}
