#!/usr/bin/env bash
# Assemble ShannonPill.app from the SwiftPM build product.
#
# SwiftPM produces a bare executable; macOS needs a bundle for LSUIElement
# (and for the pill to keep running without a dock icon). This wraps the
# universal binary in a minimal .app.
#
#   ./Scripts/make_app.sh            # debug, current arch
#   ./Scripts/make_app.sh release    # release, universal (arm64 + x86_64)

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/build/ShannonPill.app"

cd "${ROOT}"

if [[ "${CONFIG}" == "release" ]]; then
    # Prefer single-arch release on Apple Silicon; universal when SHANNON_UNIVERSAL=1.
    # Dual-arch SPM builds are fragile on newer Xcode betas and inflate CI time.
    if [[ "${SHANNON_UNIVERSAL:-0}" == "1" ]]; then
        echo "==> Building universal release binary (arm64 + x86_64)"
        swift build -c release --arch arm64 --arch x86_64
        BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ShannonPill"
    else
        echo "==> Building release binary (native arch)"
        swift build -c release
        BIN="$(swift build -c release --show-bin-path)/ShannonPill"
    fi
else
    echo "==> Building debug binary"
    swift build
    BIN="$(swift build --show-bin-path)/ShannonPill"
fi

if [[ ! -x "${BIN}" ]]; then
    echo "error: expected executable at ${BIN}" >&2
    exit 1
fi

echo "==> Assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/ShannonPill"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

# Ad-hoc signature so the bundle launches locally without a developer cert.
codesign --force --sign - --timestamp=none "${APP}" 2>/dev/null \
    || echo "warning: ad-hoc codesign failed; the app may be blocked by Gatekeeper" >&2

echo "==> Verifying LSUIElement"
if /usr/libexec/PlistBuddy -c "Print :LSUIElement" "${APP}/Contents/Info.plist" | grep -q true; then
    echo "    LSUIElement = true (no dock icon)"
else
    echo "error: LSUIElement missing from bundle Info.plist" >&2
    exit 1
fi

echo
echo "Built ${APP}"
echo "Run with:  open ${APP}            # or --args --demo for the stub media source"
echo "Stop with: pkill -f ShannonPill"
