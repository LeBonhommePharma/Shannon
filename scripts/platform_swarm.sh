#!/usr/bin/env bash
# platform_swarm.sh — coordinated multi-platform test swarm for Shannon CLI.
#
# After the Shannon UI extract, Apple lanes (ShannonCore/Theme/Pill) live in
# LeBonhommePharma/ShannonUI. This swarm:
#   - always runs Shannon CLI python / installer / scripts/shannon help|status
#   - runs Apple lanes only when SHANNON_UI_ROOT / sibling ShannonUI resolves
#   - SKIPs Apple lanes honestly (not FAIL) when UI checkout is missing
#
#   ./scripts/platform_swarm.sh              # full swarm (parallel where safe)
#   ./scripts/platform_swarm.sh --quick      # skip full Pill suite when UI present
#   ./scripts/platform_swarm.sh --sync-only  # ShannonCore iCloud/sync (needs UI)
#   ./scripts/platform_swarm.sh --installer  # pure-Python installer re-verify only
#
# Exit 0 if every *runnable* step succeeded. SKIP lines are honest, not failures.
# Logs: set SHANNON_SWARM_LOG_DIR to capture per-lane logs (default: no files).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"
# shellcheck source=lib_shannon_ui.sh
source "${REPO}/scripts/lib_shannon_ui.sh"
UI_ROOT=""
if resolve_shannon_ui; then
  UI_ROOT="${SHANNON_UI_ROOT}"
fi

QUICK=0
SYNC_ONLY=0
INSTALLER_ONLY=0
LOG_DIR="${SHANNON_SWARM_LOG_DIR:-}"

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
}

for arg in "$@"; do
  case "${arg}" in
    --quick|-q) QUICK=1 ;;
    --sync-only|--icloud) SYNC_ONLY=1 ;;
    --installer) INSTALLER_ONLY=1 ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "error: unknown option ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

info() { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; }
skip() { printf '○ SKIP %s\n' "$*"; }

ran=0
failed=0
skipped=0

run_lane() {
  local name="$1"
  shift
  ran=$((ran + 1))
  info "lane: ${name}"
  local log=""
  if [[ -n "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
    log="${LOG_DIR}/platform_swarm_${name}.log"
  fi
  set +e
  if [[ -n "${log}" ]]; then
    "$@" >"${log}" 2>&1
  else
    "$@"
  fi
  local rc=$?
  set -e
  if [[ ${rc} -eq 0 ]]; then
    ok "${name} (exit 0)"
  else
    fail "${name} (exit ${rc})"
    failed=$((failed + 1))
    if [[ -n "${log}" ]]; then
      tail -40 "${log}" >&2 || true
    fi
  fi
  return 0
}

skip_lane() {
  local name="$1"
  shift
  skipped=$((skipped + 1))
  skip "${name}: $*"
}

# ── Sync / iCloud focus (ShannonCore in ShannonUI) ────────────────────────────

run_sync_focus() {
  if [[ -z "${UI_ROOT}" ]]; then
    skip_lane "icloud_sync" "no ShannonUI checkout (set SHANNON_UI_ROOT)"
    return 0
  fi
  run_lane "icloud_sync" bash -c "
    cd \"${UI_ROOT}/Packages/ShannonCore\" && swift test --filter \
      \"SyncBehaviourTests|SecurityTests|SerializationTests|ShannonStoreAnswerTests|MultiDeviceCadenceTests|PetTests\"
  "
}

# ── Installer re-verify ───────────────────────────────────────────────────────

run_installer() {
  run_lane "installer_pytest" python3 -m pytest \
    tests/python/test_shannon_installer.py \
    tests/python/test_version_align.py -v --tb=short

  if [[ -x scripts/install_shannon.sh ]]; then
    run_lane "installer_path_update" bash -c '
      ./scripts/install_shannon.sh --path --update --skip-tests
    '
  else
    skip "install_shannon.sh not executable"
  fi

  if [[ -x scripts/shannon ]]; then
    run_lane "macos_shannon_help" ./scripts/shannon help
    run_lane "macos_shannon_status" ./scripts/shannon status || true
  fi
}

# ── Full multi-platform swarm ─────────────────────────────────────────────────

if [[ "${SYNC_ONLY}" -eq 1 ]]; then
  run_sync_focus
elif [[ "${INSTALLER_ONLY}" -eq 1 ]]; then
  run_installer
else
  if [[ -n "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
    info "parallel lane logs → ${LOG_DIR}"
  fi

  # Python CLI always runs in this repo.
  info "spawning parallel lanes: python (+ Shannon UI when present)"
  if [[ -n "${LOG_DIR}" ]]; then
    ( python3 -m pytest tests/python/ -q --tb=line ) \
      >"${LOG_DIR}/platform_swarm_python.log" 2>&1 &
    pid_py=$!
  else
    ( python3 -m pytest tests/python/ -q --tb=line ) &
    pid_py=$!
  fi

  pid_core=""
  pid_theme=""
  pid_pill=""
  if [[ -n "${UI_ROOT}" ]]; then
    info "Shannon UI root: ${UI_ROOT}"
    if [[ -n "${LOG_DIR}" ]]; then
      ( cd "${UI_ROOT}/Packages/ShannonCore" && swift test ) \
        >"${LOG_DIR}/platform_swarm_core.log" 2>&1 &
      pid_core=$!
      ( cd "${UI_ROOT}/Packages/ShannonTheme" && swift test ) \
        >"${LOG_DIR}/platform_swarm_theme.log" 2>&1 &
      pid_theme=$!
      if [[ "${QUICK}" -eq 1 ]]; then
        ( cd "${UI_ROOT}/Pill" && swift build ) \
          >"${LOG_DIR}/platform_swarm_pill.log" 2>&1 &
      else
        ( cd "${UI_ROOT}/Pill" && swift test ) \
          >"${LOG_DIR}/platform_swarm_pill.log" 2>&1 &
      fi
      pid_pill=$!
    else
      ( cd "${UI_ROOT}/Packages/ShannonCore" && swift test ) &
      pid_core=$!
      ( cd "${UI_ROOT}/Packages/ShannonTheme" && swift test ) &
      pid_theme=$!
      if [[ "${QUICK}" -eq 1 ]]; then
        ( cd "${UI_ROOT}/Pill" && swift build ) &
      else
        ( cd "${UI_ROOT}/Pill" && swift test ) &
      fi
      pid_pill=$!
    fi
  else
    skip_lane "core" "no ShannonUI checkout"
    skip_lane "theme" "no ShannonUI checkout"
    skip_lane "pill" "no ShannonUI checkout"
  fi

  set +e
  wait ${pid_py}; rc_py=$?
  rc_core=0
  rc_theme=0
  rc_pill=0
  if [[ -n "${pid_core}" ]]; then
    wait ${pid_core}; rc_core=$?
    wait ${pid_theme}; rc_theme=$?
    wait ${pid_pill}; rc_pill=$?
  fi
  set -e

  for pair in "python:${rc_py}"; do
    name="${pair%%:*}"
    rc="${pair##*:}"
    ran=$((ran + 1))
    if [[ "${rc}" -eq 0 ]]; then
      ok "${name} (exit 0)"
    else
      fail "${name} (exit ${rc})"
      failed=$((failed + 1))
      if [[ -n "${LOG_DIR}" && -f "${LOG_DIR}/platform_swarm_${name}.log" ]]; then
        tail -40 "${LOG_DIR}/platform_swarm_${name}.log" >&2 || true
      fi
    fi
  done

  if [[ -n "${pid_core}" ]]; then
    for pair in "core:${rc_core}" "theme:${rc_theme}" "pill:${rc_pill}"; do
      name="${pair%%:*}"
      rc="${pair##*:}"
      ran=$((ran + 1))
      if [[ "${rc}" -eq 0 ]]; then
        ok "${name} (exit 0)"
      else
        fail "${name} (exit ${rc})"
        failed=$((failed + 1))
        if [[ -n "${LOG_DIR}" && -f "${LOG_DIR}/platform_swarm_${name}.log" ]]; then
          tail -40 "${LOG_DIR}/platform_swarm_${name}.log" >&2 || true
        fi
      fi
    done
  fi

  run_sync_focus

  if [[ -x scripts/test_apple_platforms.sh ]]; then
    if [[ "${QUICK}" -eq 1 ]]; then
      run_lane "apple_platforms" ./scripts/test_apple_platforms.sh --quick
    else
      run_lane "apple_platforms" ./scripts/test_apple_platforms.sh
    fi
  else
    skip "test_apple_platforms.sh missing"
  fi

  run_installer
fi

echo
echo "======== platform swarm summary ========"
echo "  ran=${ran}  failed=${failed}  skipped=${skipped}"
if [[ -n "${LOG_DIR}" ]]; then
  echo "  logs: ${LOG_DIR}"
fi
if [[ -z "${UI_ROOT}" ]]; then
  echo "  note: Shannon UI lanes SKIPPED (clone ShannonUI or set SHANNON_UI_ROOT)"
fi
echo "========================================"

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
exit 0
