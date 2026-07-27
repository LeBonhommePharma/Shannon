#!/usr/bin/env bash
# validate_xcodeprojs.sh — clean-regenerate XcodeGen projects and prove they
# are loadable under the active Xcode (including Xcode-beta / macOS 27).
#
# Why this exists
# ---------------
# XcodeGen rewrites project.pbxproj but does NOT wipe extra dirs already
# sitting inside a .xcodeproj. A stray clang module cache once landed as
# iOS/Shannon.xcodeproj/-Xcc/ (~30MB of .pcm). Opening that package in
# Xcode-beta can hang indexing, thrash disk, or make first-load look
# "broken". Always delete the whole .xcodeproj before generate.
#
# This script never launches the Xcode GUI. It loads projects the same way
# xcodebuild does on first open (parse pbxproj + schemes + package refs).
#
# Usage (repo root):
#   ./scripts/validate_xcodeprojs.sh           # clean generate + load checks
#   ./scripts/validate_xcodeprojs.sh --list    # schemes only (after generate)
#   ./scripts/validate_xcodeprojs.sh --no-gen  # validate existing projects only
#   ./scripts/validate_xcodeprojs.sh --open    # after validate, open in Xcode
#                                             # (opt-in; GUI — not for agents)
#
# Exit 0 on all PASS, 1 on any FAIL.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DO_GEN=1
DO_OPEN=0
LIST_ONLY=0
TIMEOUT_LOAD="${SHANNON_XCODE_TIMEOUT:-120}"

log()  { printf '→ %s\n' "$*"; }
ok()   { printf '✓ %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; }
skip() { printf '⊘ %s\n' "$*"; }

have() { command -v "$1" >/dev/null 2>&1; }

run_timed() {
  local label="$1"; shift
  log "$label"
  if have gtimeout; then
    gtimeout "$TIMEOUT_LOAD" "$@"
  elif have timeout; then
    timeout "$TIMEOUT_LOAD" "$@"
  else
    "$@"
  fi
}

# Known-bad payloads that must never live inside a shippable/openable .xcodeproj.
# (Detect by basename — never pass '-Xcc' as a find -name arg; BSD find treats
# leading-dash patterns as options.)
is_junk_basename() {
  case "$1" in
    -Xcc|ModuleCache|ModuleCache.noindex|Index|Index.noindex|DerivedData|CompilationCache.noindex|SDKStatCaches.noindex)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

scan_junk() {
  # $1 = path to .xcodeproj — prints junk paths on stdout, returns count via echo last line no — just prints paths
  local proj="$1"
  local found=0
  while IFS= read -r -d '' p; do
    local base
    base="$(basename "$p")"
    if is_junk_basename "$base"; then
      printf '%s\n' "$p"
      found=1
    fi
  done < <(find "$proj" -mindepth 1 -maxdepth 4 -print0 2>/dev/null)
  return 0
}

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-gen) DO_GEN=0; shift ;;
    --open)   DO_OPEN=1; shift ;;
    --list)   LIST_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      fail "Unknown arg: $1"
      usage
      exit 2
      ;;
  esac
done

# ── gates ───────────────────────────────────────────────────────────────────
if ! have xcodebuild; then
  fail "xcodebuild not found — install Xcode / Xcode-beta and xcode-select it"
  exit 1
fi

echo "=== Host ==="
echo "  macOS:  $(sw_vers -productVersion 2>/dev/null || echo unknown) ($(sw_vers -buildVersion 2>/dev/null || true))"
echo "  Xcode:  $(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
echo "  DEVELOPER_DIR: ${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo unset)}"
if have xcodegen; then
  echo "  xcodegen: $(xcodegen --version 2>/dev/null | head -1)"
else
  echo "  xcodegen: MISSING"
fi
echo

FAILED=0
PASSED=0

# Project table: dir | yml-relative | expected .xcodeproj name | schemes (space-sep)
# shellcheck disable=SC2034
PROJECTS=(
  "Pill|project.yml|ShannonPill.xcodeproj|ShannonPill"
  "iOS|project.yml|Shannon.xcodeproj|ShannonPhone ShannonWatch"
  "iPad|project.yml|ShannonPad.xcodeproj|ShannonPad"
)

clean_generate_one() {
  local dir="$1" yml="$2" proj_name="$3"
  local abs="$ROOT/$dir"
  local yml_path="$abs/$yml"
  local proj_path="$abs/$proj_name"

  if [[ ! -f "$yml_path" ]]; then
    fail "$dir: missing $yml"
    return 1
  fi
  if ! have xcodegen; then
    fail "$dir: xcodegen required to generate (brew install xcodegen)"
    return 1
  fi

  # Full wipe — do not leave sibling junk (e.g. -Xcc) under the package.
  if [[ -e "$proj_path" ]]; then
    log "$dir: removing stale $proj_name"
    rm -rf "$proj_path"
  fi
  # Also remove any other *.xcodeproj that may have been left behind.
  local extra
  for extra in "$abs"/*.xcodeproj; do
    [[ -e "$extra" ]] || continue
    log "$dir: removing unexpected $(basename "$extra")"
    rm -rf "$extra"
  done

  log "$dir: xcodegen generate --spec $yml"
  (cd "$abs" && xcodegen generate --spec "$yml")
  if [[ ! -f "$proj_path/project.pbxproj" ]]; then
    fail "$dir: generate did not produce $proj_name/project.pbxproj"
    return 1
  fi
  ok "$dir: generated $proj_name"
  return 0
}

validate_one() {
  local dir="$1" proj_name="$2" schemes="$3"
  local proj_path="$ROOT/$dir/$proj_name"
  local pbx="$proj_path/project.pbxproj"
  local label="$dir/$proj_name"

  if [[ ! -f "$pbx" ]]; then
    fail "$label: project.pbxproj missing — run without --no-gen"
    return 1
  fi

  # 1) Size sanity — a healthy XcodeGen project is tens–hundreds of KB, not tens of MB.
  local size_bytes
  size_bytes="$(du -sk "$proj_path" | awk '{print $1 * 1024}')"
  local size_h
  size_h="$(du -sh "$proj_path" | awk '{print $1}')"
  if [[ "$size_bytes" -gt 5242880 ]]; then
    fail "$label: package is $size_h — suspiciously large for a generated project (possible cache junk)"
    return 1
  fi
  ok "$label: size $size_h"

  # 2) No junk directories
  local junk
  junk="$(scan_junk "$proj_path" | head -20 || true)"
  if [[ -n "$junk" ]]; then
    fail "$label: junk inside .xcodeproj (will hurt Xcode first-load):"
    printf '%s\n' "$junk" | sed 's/^/    /' >&2
    return 1
  fi
  ok "$label: no module-cache / -Xcc / DerivedData junk"

  # 3) pbxproj is well-formed OpenStep / plist text
  if ! plutil -lint "$pbx" >/dev/null; then
    fail "$label: plutil -lint failed"
    plutil -lint "$pbx" >&2 || true
    return 1
  fi
  # Must start with Xcode UTF-8 header (not binary plist)
  if ! head -1 "$pbx" | grep -q 'UTF8'; then
    fail "$label: project.pbxproj missing // !\$*UTF8*\$! header (binary or corrupt?)"
    return 1
  fi
  ok "$label: project.pbxproj lint OK"

  # 4) Minimal structural keys Xcode requires
  if ! grep -q 'objectVersion' "$pbx"; then
    fail "$label: no objectVersion"
    return 1
  fi
  if ! grep -q 'PBXProject' "$pbx"; then
    fail "$label: no PBXProject section"
    return 1
  fi
  ok "$label: objectVersion + PBXProject present"

  # 5) Workspace self-ref (broken contents.xcworkspacedata → Xcode won't open)
  local ws="$proj_path/project.xcworkspace/contents.xcworkspacedata"
  if [[ ! -f "$ws" ]]; then
    fail "$label: missing project.xcworkspace/contents.xcworkspacedata"
    return 1
  fi
  if ! grep -q 'location = "self:"' "$ws"; then
    fail "$label: workspace does not reference self: (corrupt workspace)"
    return 1
  fi
  ok "$label: workspace self-ref OK"

  # 6) Load via xcodebuild (same parse path as GUI open, no GUI)
  local list_out
  if ! list_out="$(run_timed "$label: xcodebuild -list" \
      xcodebuild -project "$proj_path" -list 2>&1)"; then
    fail "$label: xcodebuild -list failed — project is not loadable"
    printf '%s\n' "$list_out" | tail -40 >&2
    return 1
  fi
  ok "$label: xcodebuild -list loaded project"

  # 7) Expected schemes exist
  local sch
  for sch in $schemes; do
    if ! printf '%s\n' "$list_out" | grep -qE "^[[:space:]]*${sch}[[:space:]]*$"; then
      fail "$label: scheme '$sch' not listed by xcodebuild -list"
      printf '%s\n' "$list_out" | sed -n '/Schemes:/,/^$/p' >&2
      return 1
    fi
  done
  ok "$label: schemes present ($schemes)"

  # 8) Lightweight settings resolve (forces package path resolution)
  local first_scheme
  first_scheme="$(echo "$schemes" | awk '{print $1}')"
  if ! run_timed "$label: showBuildSettings ($first_scheme)" \
      xcodebuild -project "$proj_path" -scheme "$first_scheme" \
        -showBuildSettings \
        CODE_SIGNING_ALLOWED=NO \
        >/dev/null 2>&1; then
    fail "$label: -showBuildSettings failed for scheme $first_scheme (broken package refs?)"
    return 1
  fi
  ok "$label: build settings resolve for $first_scheme"

  if [[ "$LIST_ONLY" -eq 1 ]]; then
    echo "---- $label schemes ----"
    printf '%s\n' "$list_out"
  fi

  return 0
}

# ── main ────────────────────────────────────────────────────────────────────
for row in "${PROJECTS[@]}"; do
  IFS='|' read -r dir yml proj_name schemes <<<"$row"
  echo "======== $dir ========"
  if [[ "$DO_GEN" -eq 1 ]]; then
    if ! clean_generate_one "$dir" "$yml" "$proj_name"; then
      FAILED=$((FAILED + 1))
      echo
      continue
    fi
  fi
  if validate_one "$dir" "$proj_name" "$schemes"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
  echo
done

echo "======== Xcode project validation ========"
echo "  passed=$PASSED  failed=$FAILED"
echo "  Xcode: $(xcodebuild -version 2>/dev/null | head -1)"
echo "=========================================="

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi

if [[ "$DO_OPEN" -eq 1 ]]; then
  log "Opening projects in Xcode (GUI) — you asked for --open"
  open "$ROOT/Pill/ShannonPill.xcodeproj"
  open "$ROOT/iOS/Shannon.xcodeproj"
  open "$ROOT/iPad/ShannonPad.xcodeproj"
  ok "open dispatched (if Xcode hangs, kill it and re-run WITHOUT --open; junk should already be gone)"
else
  ok "Projects are loadable via xcodebuild. Safe to: open Pill/ShannonPill.xcodeproj (etc.)"
  ok "Tip: prefer './scripts/validate_xcodeprojs.sh' after any xcodegen; never open a bloated .xcodeproj"
fi

exit 0
