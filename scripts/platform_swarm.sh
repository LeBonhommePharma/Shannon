#!/usr/bin/env bash
# platform_swarm.sh — coordinated multi-platform test swarm for Shannon.
#
# Runs the real operator entry points used in docs/APPLE_PLATFORM_TESTING.md:
#   macOS packages (ShannonCore, ShannonTheme), Pill, pure-Python science +
#   installer tests, and Apple mobile unsigned builds (iOS / iPad / watch).
#
#   ./scripts/platform_swarm.sh              # full swarm (parallel where safe)
#   ./scripts/platform_swarm.sh --quick      # skip full Pill suite (build + packages)
#   ./scripts/platform_swarm.sh --sync-only  # ShannonCore iCloud/sync focus suites
#   ./scripts/platform_swarm.sh --installer  # pure-Python installer re-verify only
#
# Exit 0 if every *runnable* step succeeded. SKIP lines are honest, not failures.
# Logs: set SHANNON_SWARM_LOG_DIR to capture per-lane logs (default: no files).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"

QUICK=0
SYNC_ONLY=0
INSTALLER_ONLY=0
LOG_DIR="${SHANNON_SWARM_LOG_DIR:-}"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \?//'
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

# ── Sync / iCloud focus (ShannonCore) ─────────────────────────────────────────

run_sync_focus() {
  run_lane "icloud_sync" bash -c '
    cd Packages/ShannonCore && swift test --filter \
      "SyncBehaviourTests|SecurityTests|SerializationTests|ShannonStoreAnswerTests|MultiDeviceCadenceTests|PetTests"
  '
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
  # Parallel package + python lanes; apple platforms sequential after (Xcode heavy).
  # When SHANNON_SWARM_LOG_DIR is set, each parallel lane also gets a log file
  # (same naming as run_lane: platform_swarm_<name>.log) and tails on failure.
  # IMPORTANT: background with `cmd &; pid=$!` in *this* shell — never
  # `pid=$(fn …)` which reparents the job into a subshell and breaks wait.
  if [[ -n "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
    info "parallel lane logs → ${LOG_DIR}"
  fi
  info "spawning parallel lanes: core theme pill python"

  if [[ -n "${LOG_DIR}" ]]; then
    ( cd Packages/ShannonCore && swift test ) \
      >"${LOG_DIR}/platform_swarm_core.log" 2>&1 &
    pid_core=$!
    ( cd Packages/ShannonTheme && swift test ) \
      >"${LOG_DIR}/platform_swarm_theme.log" 2>&1 &
    pid_theme=$!
    if [[ "${QUICK}" -eq 1 ]]; then
      ( cd Pill && swift build ) \
        >"${LOG_DIR}/platform_swarm_pill.log" 2>&1 &
    else
      ( cd Pill && swift test ) \
        >"${LOG_DIR}/platform_swarm_pill.log" 2>&1 &
    fi
    pid_pill=$!
    ( python3 -m pytest tests/python/ -q --tb=line ) \
      >"${LOG_DIR}/platform_swarm_python.log" 2>&1 &
    pid_py=$!
  else
    ( cd Packages/ShannonCore && swift test ) &
    pid_core=$!
    ( cd Packages/ShannonTheme && swift test ) &
    pid_theme=$!
    if [[ "${QUICK}" -eq 1 ]]; then
      ( cd Pill && swift build ) &
    else
      ( cd Pill && swift test ) &
    fi
    pid_pill=$!
    ( python3 -m pytest tests/python/ -q --tb=line ) &
    pid_py=$!
  fi

  set +e
  wait ${pid_core}; rc_core=$?
  wait ${pid_theme}; rc_theme=$?
  wait ${pid_pill}; rc_pill=$?
  wait ${pid_py}; rc_py=$?
  set -e

  for pair in "core:${rc_core}" "theme:${rc_theme}" "pill:${rc_pill}" "python:${rc_py}"; do
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
echo "  ran=${ran}  failed=${failed}"
if [[ -n "${LOG_DIR}" ]]; then
  echo "  logs: ${LOG_DIR}"
fi
echo "========================================"

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
exit 0
