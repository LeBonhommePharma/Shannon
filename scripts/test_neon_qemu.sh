#!/usr/bin/env bash
# test_neon_qemu.sh — Cross-compile and validate the NEON entropy kernels
# under qemu-aarch64 on an x86_64 host.
#
# This makes the NEON transcendental kernels (simd_exp.hpp / simd_log2.hpp
# NEON sections, entropy_neon.cpp) testable in CI without ARM hardware:
# accuracy vs libm, equivalence vs the scalar reference kernels, and analytic
# ground truths all run under emulation. QEMU emulates instruction semantics
# faithfully, so accuracy/correctness results transfer to real hardware;
# PERFORMANCE numbers under QEMU are meaningless — benchmark on real Apple
# Silicon / Graviton for those.
#
# Requirements (Ubuntu/Debian):
#   apt-get install g++-aarch64-linux-gnu qemu-user-static
#
# Usage: scripts/test_neon_qemu.sh
#
# Apache-2.0 © 2026 Le Bonhomme Pharma
set -euo pipefail

cd "$(dirname "$0")/.."

CXX=${CROSS_CXX:-aarch64-linux-gnu-g++}
QEMU=${QEMU:-qemu-aarch64-static}

command -v "$CXX"  >/dev/null || { echo "missing $CXX (apt-get install g++-aarch64-linux-gnu)"; exit 2; }
command -v "$QEMU" >/dev/null || { echo "missing $QEMU (apt-get install qemu-user-static)"; exit 2; }

# The generated config header: prefer an existing build tree, else generate one.
GEN_DIR=build/generated
if [ ! -f "$GEN_DIR/shannon/config.hpp" ]; then
    GEN_DIR=$(mktemp -d)/generated
    mkdir -p "$GEN_DIR/shannon"
    VER=$(cat VERSION)
    MAJOR=${VER%%.*}; REST=${VER#*.}; MINOR=${REST%%.*}; PATCH=${VER##*.}
    sed -e "s/@shannon_VERSION_MAJOR@/${MAJOR}/" \
        -e "s/@shannon_VERSION_MINOR@/${MINOR}/" \
        -e "s/@shannon_VERSION_PATCH@/${PATCH}/" \
        src/shannon/config.hpp.in > "$GEN_DIR/shannon/config.hpp"
fi

OUT=$(mktemp -d)
echo "cross-compiling NEON kernel tests ($CXX)..."
"$CXX" -std=c++20 -O2 -static \
    -DSHANNON_USE_NEON \
    -I src -I "$GEN_DIR" \
    tests/cpp/test_neon_kernels.cpp \
    src/shannon/entropy_neon.cpp \
    src/shannon/entropy_scalar.cpp \
    -o "$OUT/test_neon_kernels"

echo "running under $QEMU..."
"$QEMU" "$OUT/test_neon_kernels"
