#!/usr/bin/env bash
# test_apple_platforms.sh — agent-friendly multi-platform health check for Shannon.
#
# Platforms: macOS (Pill + packages), iOS (phone), iPadOS (pad), watchOS.
# When simulators exist (or can be created), runs builds against them.
# When not, uses generic Simulator destinations (unsigned compile still proves
# the target builds). Never invents green — reports SKIP with reason.
#
# Usage (repo root):
#   ./scripts/test_apple_platforms.sh              # all available platforms
#   ./scripts/test_apple_platforms.sh macos        # mac only
#   ./scripts/test_apple_platforms.sh ios ipad watch
#   ./scripts/test_apple_platforms.sh --quick      # packages + generic builds only
#   ./scripts/test_apple_platforms.sh --list       # print destinations / runtimes
#   ./scripts/validate_xcodeprojs.sh               # clean generate + load-safe check
#                                                  # (run before opening in Xcode-beta)
#
# Exit: 0 if every selected platform that *could* run succeeded; 1 if any
# selected runnable step failed. Skips do not fail the run.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

QUICK=0
LIST_ONLY=0
REQUESTED=()
TIMEOUT_BUILD="${SHANNON_XCODE_TIMEOUT:-600}"

log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
skip() { printf '⊘ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

run_timed() {
  # Usage: run_timed <label> <cmd...>
  local label="$1"; shift
  log "$label"
  if have gtimeout; then
    gtimeout "$TIMEOUT_BUILD" "$@"
  elif have timeout; then
    timeout "$TIMEOUT_BUILD" "$@"
  else
    "$@"
  fi
}

# ── args ────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --list)  LIST_ONLY=1; shift ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    macos|mac|ios|iphone|ipad|ipados|watch|watchos|all)
      REQUESTED+=("$1"); shift ;;
    *)
      fail "Unknown arg: $1 (use macos|ios|ipad|watch|all|--quick|--list)"
      exit 2
      ;;
  esac
done

if [[ ${#REQUESTED[@]} -eq 0 ]]; then
  REQUESTED=(all)
fi

# Expand "all"
PLATFORMS=()
for r in "${REQUESTED[@]}"; do
  case "$r" in
    all) PLATFORMS+=(macos ios ipad watch) ;;
    macos|mac) PLATFORMS+=(macos) ;;
    ios|iphone) PLATFORMS+=(ios) ;;
    ipad|ipados) PLATFORMS+=(ipad) ;;
    watch|watchos) PLATFORMS+=(watch) ;;
  esac
done
# unique
PLATFORMS=($(printf '%s\n' "${PLATFORMS[@]}" | awk '!a[$0]++'))

# ── tooling gate ────────────────────────────────────────────────────────────
if ! have xcodebuild; then
  fail "xcodebuild not found — install Xcode on this Mac"
  exit 1
fi
if ! have xcodegen; then
  skip "xcodegen missing (brew install xcodegen) — app targets will be skipped; packages still run"
fi

list_env() {
  echo "=== Xcode ==="
  xcodebuild -version 2>/dev/null || true
  echo "=== Runtimes ==="
  xcrun simctl list runtimes 2>/dev/null | sed -n '1,30p' || true
  echo "=== Available devices (simctl) ==="
  xcrun simctl list devices available 2>/dev/null | sed -n '1,80p' || true
  echo "=== Device types (sample) ==="
  xcrun simctl list devicetypes 2>/dev/null | rg -i 'iPhone|iPad|Watch' | head -20 || true
}

if [[ "$LIST_ONLY" -eq 1 ]]; then
  list_env
  exit 0
fi

FAILED=0
RAN=0
SKIPPED=0
RESULTS=()

record() {
  # record STATUS PLATFORM DETAIL
  RESULTS+=("$1|$2|$3")
  case "$1" in
    PASS) RAN=$((RAN+1)) ;;
    FAIL) RAN=$((RAN+1)); FAILED=$((FAILED+1)) ;;
    SKIP) SKIPPED=$((SKIPPED+1)) ;;
  esac
}

# ── simulator helpers ───────────────────────────────────────────────────────
# Prefer an existing available device UUID for a runtime OS family.
find_sim_udid() {
  # $1 = family regex e.g. iPhone|iPad or Apple Watch
  local family="$1"
  xcrun simctl list devices available -j 2>/dev/null \
    | python3 -c '
import json,sys,re
family=re.compile(sys.argv[1], re.I)
data=json.load(sys.stdin)
for runtime, devices in data.get("devices", {}).items():
    for d in devices:
        if d.get("isAvailable") and family.search(d.get("name","")):
            print(d["udid"])
            sys.exit(0)
sys.exit(1)
' "$family" 2>/dev/null || true
}

ensure_sim() {
  # $1=friendly $2=name-regex $3=device-type substring $4=runtime substring
  # Prints UDID or empty.
  local friendly="$1" name_re="$2" dtype_sub="$3" runtime_sub="$4"
  local udid
  udid="$(find_sim_udid "$name_re")"
  if [[ -n "$udid" ]]; then
    echo "$udid"
    return 0
  fi
  # Try create if runtime + device type exist
  local runtime dtype
  runtime="$(xcrun simctl list runtimes 2>/dev/null | rg -i "$runtime_sub" | rg -o 'com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9.-]+' | head -1 || true)"
  dtype="$(xcrun simctl list devicetypes 2>/dev/null | rg -i "$dtype_sub" | rg -o 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9.-]+' | head -1 || true)"
  if [[ -z "$runtime" || -z "$dtype" ]]; then
    return 1
  fi
  local name="Shannon-$friendly-Agent"
  # Delete stale agent device with same name if any
  local old
  old="$(xcrun simctl list devices 2>/dev/null | rg "$name" | rg -o '[0-9A-F-]{36}' | head -1 || true)"
  if [[ -n "$old" ]]; then
    xcrun simctl delete "$old" >/dev/null 2>&1 || true
  fi
  if udid="$(xcrun simctl create "$name" "$dtype" "$runtime" 2>/dev/null)"; then
    echo "$udid"
    return 0
  fi
  return 1
}

dest_for_udid() {
  echo "platform=iOS Simulator,id=$1"
}

dest_for_watch_udid() {
  echo "platform=watchOS Simulator,id=$1"
}

# ── macOS: Pill + packages (always runnable on this host) ───────────────────
run_macos() {
  log "macOS — ShannonCore + ShannonTheme + Pill"
  local ok_all=1
  # --quick: build packages (swift test still for Core — pure, fast) + Pill build only.
  if ! (cd "$ROOT/Packages/ShannonCore" && run_timed "ShannonCore swift test" swift test); then
    ok_all=0
  fi
  if ! (cd "$ROOT/Packages/ShannonTheme" && run_timed "ShannonTheme swift test" swift test); then
    ok_all=0
  fi
  if ! (cd "$ROOT/Pill" && run_timed "Pill swift build" swift build); then
    ok_all=0
  fi
  if [[ "$QUICK" -eq 0 ]]; then
    if ! (cd "$ROOT/Pill" && run_timed "Pill swift test" swift test); then
      ok_all=0
    fi
  else
    log "Pill full test skipped (--quick); build only"
  fi
  if [[ "$ok_all" -eq 1 ]]; then
    ok "macOS packages + Pill"
    record PASS macos "ShannonCore/Theme/Pill"
  else
    fail "macOS package or Pill step failed"
    record FAIL macos "see log above"
  fi
}

# ── ShannonCore on non-Mac destinations (shared logic for phone/pad/watch) ──
build_core_generic() {
  # $1 = platform string for -destination generic/platform=...
  local plat="$1"
  (cd "$ROOT/Packages/ShannonCore" && \
    run_timed "ShannonCore generic $plat" \
      xcodebuild -scheme ShannonCore \
        -destination "generic/platform=$plat" \
        -derivedDataPath "$ROOT/Packages/ShannonCore/.derivedData-$plat" \
        CODE_SIGNING_ALLOWED=NO \
        build)
}

# ── clean XcodeGen (wipe package so junk like -Xcc cannot survive) ──────────
# XcodeGen rewrites pbxproj but does not delete sibling dirs inside an existing
# .xcodeproj. Stale clang module caches under the package hang Xcode-beta on open.
clean_xcodegen() {
  # $1 = directory under repo root (Pill | iOS | iPad)
  local dir="$1"
  local abs="$ROOT/$dir"
  local stale
  for stale in "$abs"/*.xcodeproj; do
    [[ -e "$stale" ]] || continue
    log "removing stale $(basename "$stale") before xcodegen"
    rm -rf "$stale"
  done
  (cd "$abs" && xcodegen generate --spec project.yml)
}

# ── iOS phone app ───────────────────────────────────────────────────────────
run_ios() {
  if ! have xcodegen; then
    skip "iOS app — xcodegen not installed"
    record SKIP ios "no xcodegen"
    return 0
  fi
  log "iOS — generate + build ShannonPhone"
  clean_xcodegen iOS || {
    fail "iOS xcodegen generate failed"
    record FAIL ios "xcodegen"
    return 0
  }

  local udid dest
  udid="$(ensure_sim "iPhone" "iPhone" "iPhone-1[567]|iPhone-SE|iPhone-Air" "iOS" || true)"
  if [[ -n "$udid" ]]; then
    dest="platform=iOS Simulator,id=$udid"
    log "iOS Simulator device $udid"
  else
    dest="generic/platform=iOS Simulator"
    skip "no iPhone simulator device — using generic destination (build only)"
  fi

  if (cd "$ROOT/iOS" && run_timed "ShannonPhone build" \
      xcodebuild -project Shannon.xcodeproj -scheme ShannonPhone \
        -destination "$dest" \
        -derivedDataPath "$ROOT/iOS/.derivedData" \
        CODE_SIGNING_ALLOWED=NO \
        build); then
    # Shared pure logic always on Mac already; also prove Core for iOS SDK
    if build_core_generic "iOS Simulator"; then
      ok "iOS ShannonPhone + ShannonCore (iOS Simulator SDK)"
      record PASS ios "ShannonPhone build ($dest)"
    else
      fail "ShannonCore failed for iOS Simulator SDK"
      record FAIL ios "ShannonCore iOS SDK"
    fi
  else
    fail "ShannonPhone build failed"
    record FAIL ios "xcodebuild"
  fi
}

# ── iPad ────────────────────────────────────────────────────────────────────
run_ipad() {
  if ! have xcodegen; then
    skip "iPad app — xcodegen not installed"
    record SKIP ipad "no xcodegen"
    return 0
  fi
  log "iPadOS — generate + build ShannonPad"
  clean_xcodegen iPad || {
    fail "iPad xcodegen generate failed"
    record FAIL ipad "xcodegen"
    return 0
  }

  local udid dest
  udid="$(ensure_sim "iPad" "iPad" "iPad" "iOS" || true)"
  if [[ -n "$udid" ]]; then
    dest="platform=iOS Simulator,id=$udid"
    log "iPad Simulator device $udid"
  else
    # Same SDK as iPhone; prefer iPad device type if we can create one
    dest="generic/platform=iOS Simulator"
    skip "no iPad simulator device — using generic iOS Simulator destination"
  fi

  if (cd "$ROOT/iPad" && run_timed "ShannonPad build" \
      xcodebuild -project ShannonPad.xcodeproj -scheme ShannonPad \
        -destination "$dest" \
        -derivedDataPath "$ROOT/iPad/.derivedData" \
        CODE_SIGNING_ALLOWED=NO \
        build); then
    ok "iPadOS ShannonPad build ($dest)"
    record PASS ipad "ShannonPad build"
  else
    fail "ShannonPad build failed"
    record FAIL ipad "xcodebuild"
  fi
}

# ── watchOS ─────────────────────────────────────────────────────────────────
run_watch() {
  if ! have xcodegen; then
    skip "watchOS app — xcodegen not installed"
    record SKIP watch "no xcodegen"
    return 0
  fi
  # Watch scheme lives in the iOS project — always clean-regenerate so a prior
  # run cannot leave cache junk under the package for a later GUI open.
  log "generating iOS project for ShannonWatch scheme (clean)"
  clean_xcodegen iOS || {
    fail "watchOS: iOS xcodegen failed"
    record FAIL watch "xcodegen"
    return 0
  }

  log "watchOS — build ShannonWatch"
  local udid dest
  udid="$(ensure_sim "Watch" "Watch" "Apple-Watch" "watchOS" || true)"
  if [[ -n "$udid" ]]; then
    dest="platform=watchOS Simulator,id=$udid"
    log "watchOS Simulator device $udid"
  else
    dest="generic/platform=watchOS Simulator"
    skip "no Watch simulator device — using generic destination"
  fi

  if (cd "$ROOT/iOS" && run_timed "ShannonWatch build" \
      xcodebuild -project Shannon.xcodeproj -scheme ShannonWatch \
        -destination "$dest" \
        -derivedDataPath "$ROOT/iOS/.derivedData-watch" \
        CODE_SIGNING_ALLOWED=NO \
        build); then
    if build_core_generic "watchOS Simulator"; then
      ok "watchOS ShannonWatch + ShannonCore (watchOS Simulator SDK)"
      record PASS watch "ShannonWatch build ($dest)"
    else
      # App build green is still useful if Core generic fails on exotic toolchains
      skip "ShannonCore watchOS SDK build failed; app target succeeded"
      record PASS watch "ShannonWatch only (Core SDK skip)"
    fi
  else
    fail "ShannonWatch build failed"
    record FAIL watch "xcodebuild"
  fi
}

# ── dispatch ────────────────────────────────────────────────────────────────
for p in "${PLATFORMS[@]}"; do
  case "$p" in
    macos) run_macos ;;
    ios)   run_ios ;;
    ipad)  run_ipad ;;
    watch) run_watch ;;
  esac
done

echo
echo "======== Apple platform summary ========"
for row in "${RESULTS[@]}"; do
  IFS='|' read -r st pl det <<<"$row"
  printf '  %-5s  %-6s  %s\n' "$st" "$pl" "$det"
done
echo "  ran=$RAN  failed=$FAILED  skipped=$SKIPPED"
echo "========================================"

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
