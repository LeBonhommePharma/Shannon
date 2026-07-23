#!/usr/bin/env bash
# setup.sh — Shannon developer bootstrap
#
# Run once after cloning:
#   git clone https://github.com/LeBonhommePharma/Shannon && cd Shannon && ./setup.sh
#
# Idempotent: safe to run again after updates.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

# ─── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[setup]${NC} $*"; }
success() { echo -e "${GREEN}[setup]${NC} $*"; }
warn()    { echo -e "${YELLOW}[setup]${NC} $*"; }
die()     { echo -e "${RED}[setup] ERROR:${NC} $*" >&2; exit 1; }

# ─── Step 1 · Xcode ────────────────────────────────────────────────────────────
info "Checking Xcode..."
if ! xcode-select -p &>/dev/null; then
  die "Xcode not found. Install Xcode from the App Store first, then re-run this script."
fi
success "Xcode found at $(xcode-select -p)"

# Accept Xcode license if needed (no-op if already accepted).
if ! xcodebuild -version &>/dev/null 2>&1; then
  warn "Accepting Xcode license (may require sudo)..."
  sudo xcodebuild -license accept
fi

# ─── Step 2 · Homebrew ─────────────────────────────────────────────────────────
info "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  info "Homebrew not found — installing..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for this session on Apple Silicon.
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi
success "Homebrew $(brew --version | head -1)"

# ─── Step 3 · brew bundle ──────────────────────────────────────────────────────
info "Installing dependencies from Brewfile..."
brew bundle install --no-lock --file="$REPO_ROOT/Brewfile"
success "Homebrew dependencies installed."

# ─── Step 4 · Python virtual environment ───────────────────────────────────────
info "Setting up Python virtual environment..."
if [[ ! -d "$REPO_ROOT/.venv" ]]; then
  python3 -m venv "$REPO_ROOT/.venv"
  info "Virtual environment created at .venv"
else
  info "Virtual environment already exists — skipping creation."
fi

# shellcheck disable=SC1090
source "$REPO_ROOT/.venv/bin/activate"
info "Installing Python package (editable + dev extras)..."
pip install -e ".[dev]" -q
success "Python environment ready."

# ─── Step 5 · Generate Xcode projects ──────────────────────────────────────────
info "Generating Xcode projects with XcodeGen..."

for target_dir in Pill iOS iPad; do
  proj_yml="$REPO_ROOT/$target_dir/project.yml"
  if [[ ! -f "$proj_yml" ]]; then
    die "$proj_yml not found. Is this a complete Shannon clone?"
  fi
  info "  xcodegen generate — $target_dir/"
  (cd "$REPO_ROOT/$target_dir" && xcodegen generate --spec project.yml)
  success "  $target_dir/.xcodeproj generated."
done

# ─── Step 6 · Swift package resolve ───────────────────────────────────────────
info "Resolving Swift package dependencies..."

for pkg in ShannonCore ShannonTheme; do
  pkg_path="$REPO_ROOT/Packages/$pkg"
  if [[ ! -f "$pkg_path/Package.swift" ]]; then
    warn "  $pkg not found at $pkg_path — skipping."
    continue
  fi
  info "  swift package resolve — Packages/$pkg"
  (cd "$pkg_path" && swift package resolve)
  success "  Packages/$pkg resolved."
done

# ─── Done ──────────────────────────────────────────────────────────────────────
success ""
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
success "  Shannon is ready. Available Fastlane lanes:"
success ""
success "  fastlane pill          — build + launch the macOS Pill"
success "  fastlane ios_sim       — run on iPhone simulator"
success "  fastlane ipad_sim      — run on iPad simulator"
success "  fastlane all_sim       — run all simulators + Pill"
success ""
success "  fastlane ios_device    — install on connected iPhone"
success "  fastlane ipad_device   — install on connected iPad"
success "  fastlane watch_device  — install iOS + embedded Watch app"
success "  fastlane all_device    — install on all connected devices"
success ""
success "  fastlane beta          — upload to TestFlight"
success "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
