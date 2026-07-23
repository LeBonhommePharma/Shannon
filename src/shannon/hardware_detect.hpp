// hardware_detect.hpp — Runtime hardware capability detection for Shannon 2.0
//
// Ported from FlexAIDdS hardware_detect.h into shannon::hw namespace.
// Probes CPU SIMD (x86/ARM), GPU (CUDA/ROCm/Metal), OpenMP, and Eigen.
// Result is cached after first call (Meyers singleton).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

namespace shannon::hw {

struct HardwareCapabilities {
    // GPU backends (CUDA/ROCm/Metal) were removed — CPU-only streaming workload.

    // ── SIMD: x86-64 ──
    bool has_sse42      = false;
    bool has_avx2       = false;
    bool has_fma        = false;
    bool has_avx512f    = false;
    bool has_avx512dq   = false;
    bool has_avx512bw   = false;
    bool has_avx512vnni = false;
    bool has_avx512     = false;   // composite: f && dq && bw

    // ── SIMD: ARM ──
    bool has_neon       = false;   // ASIMD / NEON (always true on aarch64)
    bool has_neon_fma   = false;   // fused multiply-add (ARMv8+)
    bool has_sve        = false;   // Scalable Vector Extension (AArch64)

    // ── OpenMP ──
    bool has_openmp           = false;
    int  openmp_max_threads   = 1;

    // ── Eigen ──
    bool has_eigen = false;

    std::string summary() const;
};

const HardwareCapabilities& detect_hardware();

}  // namespace shannon::hw
