// entropy_neon.cpp — ARM NEON entropy kernels for Shannon 2.0
//
// Compiled for aarch64/ARM with NEON (ASIMD). Implements all three entropy
// entry points so UnifiedDispatch can keep NEON as the default CPU backend
// on Apple Silicon and other aarch64 hosts.
//
// The transcendentals are fully vectorized via shannon_exp_neon /
// shannon_log2_neon (simd_exp.hpp / simd_log2.hpp) — the same range-reduced
// polynomial kernels used by the AVX2/AVX-512 paths, ported to float64x2_t.
// Earlier revisions stored each vector to the stack and called scalar
// std::exp / std::log2 per lane, pinning throughput at scalar-libm speed.
// Validated under qemu-aarch64 (scripts/test_neon_qemu.sh) and runnable
// natively on Apple Silicon via the same harness.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>

#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"

namespace shannon::kernels {

#if defined(SHANNON_USE_NEON)

namespace {

// Horizontal max of float64x2_t
[[nodiscard]] inline double hmax_f64x2(float64x2_t v) noexcept {
    return std::fmax(vgetq_lane_f64(v, 0), vgetq_lane_f64(v, 1));
}

// Horizontal sum of float64x2_t
[[nodiscard]] inline double hsum_f64x2(float64x2_t v) noexcept {
    return vgetq_lane_f64(v, 0) + vgetq_lane_f64(v, 1);
}

// NEON-accelerated max reduction over doubles
[[nodiscard]] inline double neon_max(const double* w, std::size_t n) noexcept {
    float64x2_t vmax = vdupq_n_f64(w[0]);
    std::size_t i = 0;
    // 4-wide unroll (2x float64x2) for better ILP on Apple Silicon
    for (; i + 3 < n; i += 4) {
        float64x2_t a = vld1q_f64(w + i);
        float64x2_t b = vld1q_f64(w + i + 2);
        vmax = vmaxq_f64(vmax, a);
        vmax = vmaxq_f64(vmax, b);
    }
    for (; i + 1 < n; i += 2) {
        vmax = vmaxq_f64(vmax, vld1q_f64(w + i));
    }
    double max_w = hmax_f64x2(vmax);
    for (; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }
    return max_w;
}

}  // namespace

double configurational_entropy_neon(const double* w, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    const double max_w = neon_max(w, n);

    float64x2_t v_max  = vdupq_n_f64(max_w);
    float64x2_t acc_Z  = vdupq_n_f64(0.0);
    float64x2_t acc_ws = vdupq_n_f64(0.0);

    std::size_t i = 0;
    // 4-wide outer step: two NEON pairs per iteration (better pipeline use)
    for (; i + 3 < n; i += 4) {
        float64x2_t sh0 = vsubq_f64(vld1q_f64(w + i),     v_max);
        float64x2_t sh1 = vsubq_f64(vld1q_f64(w + i + 2), v_max);

        float64x2_t ev0 = simd::shannon_exp_neon(sh0);
        float64x2_t ev1 = simd::shannon_exp_neon(sh1);

        acc_Z  = vaddq_f64(acc_Z, ev0);
        acc_Z  = vaddq_f64(acc_Z, ev1);
        acc_ws = vfmaq_f64(acc_ws, sh0, ev0);  // acc += sh * exp(sh)
        acc_ws = vfmaq_f64(acc_ws, sh1, ev1);
    }

    for (; i + 1 < n; i += 2) {
        float64x2_t sh = vsubq_f64(vld1q_f64(w + i), v_max);
        float64x2_t ev = simd::shannon_exp_neon(sh);
        acc_Z  = vaddq_f64(acc_Z, ev);
        acc_ws = vfmaq_f64(acc_ws, sh, ev);
    }

    double Z  = hsum_f64x2(acc_Z);
    double ws = hsum_f64x2(acc_ws);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_neon(const double* p, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    const float64x2_t v_eps  = vdupq_n_f64(kEpsilon);
    const float64x2_t v_zero = vdupq_n_f64(0.0);
    float64x2_t acc = vdupq_n_f64(0.0);
    std::size_t i = 0;

    // contrib = -p * log2(p), masked to 0 where p <= kEpsilon
    for (; i + 3 < n; i += 4) {
        float64x2_t p0 = vld1q_f64(p + i);
        float64x2_t p1 = vld1q_f64(p + i + 2);

        float64x2_t c0 = vnegq_f64(vmulq_f64(p0, simd::shannon_log2_neon(p0)));
        float64x2_t c1 = vnegq_f64(vmulq_f64(p1, simd::shannon_log2_neon(p1)));

        uint64x2_t m0 = vcgtq_f64(p0, v_eps);
        uint64x2_t m1 = vcgtq_f64(p1, v_eps);
        acc = vaddq_f64(acc, vbslq_f64(m0, c0, v_zero));
        acc = vaddq_f64(acc, vbslq_f64(m1, c1, v_zero));
    }

    for (; i + 1 < n; i += 2) {
        float64x2_t vp = vld1q_f64(p + i);
        float64x2_t c  = vnegq_f64(vmulq_f64(vp, simd::shannon_log2_neon(vp)));
        acc = vaddq_f64(acc, vbslq_f64(vcgtq_f64(vp, v_eps), c, v_zero));
    }

    double h = hsum_f64x2(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_neon(const double* lp, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    const float64x2_t v_log2e = vdupq_n_f64(kLog2E);
    const float64x2_t v_eps   = vdupq_n_f64(kEpsilon);
    const float64x2_t v_zero  = vdupq_n_f64(0.0);
    float64x2_t acc = vdupq_n_f64(0.0);
    std::size_t i = 0;

    // contrib = -exp(lp) * lp * log2(e), masked to 0 where p <= kEpsilon
    for (; i + 3 < n; i += 4) {
        float64x2_t lp0 = vld1q_f64(lp + i);
        float64x2_t lp1 = vld1q_f64(lp + i + 2);

        float64x2_t p0 = simd::shannon_exp_neon(lp0);
        float64x2_t p1 = simd::shannon_exp_neon(lp1);

        float64x2_t c0 = vnegq_f64(vmulq_f64(p0, lp0));
        float64x2_t c1 = vnegq_f64(vmulq_f64(p1, lp1));

        uint64x2_t m0 = vcgtq_f64(p0, v_eps);
        uint64x2_t m1 = vcgtq_f64(p1, v_eps);
        acc = vfmaq_f64(acc, vbslq_f64(m0, c0, v_zero), v_log2e);
        acc = vfmaq_f64(acc, vbslq_f64(m1, c1, v_zero), v_log2e);
    }

    for (; i + 1 < n; i += 2) {
        float64x2_t vlp = vld1q_f64(lp + i);
        float64x2_t p   = simd::shannon_exp_neon(vlp);
        float64x2_t c   = vnegq_f64(vmulq_f64(p, vlp));
        acc = vfmaq_f64(acc, vbslq_f64(vcgtq_f64(p, v_eps), c, v_zero), v_log2e);
    }

    double h = hsum_f64x2(acc);
    for (; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::fmax(0.0, h);
}

#endif  // SHANNON_USE_NEON

}  // namespace shannon::kernels

#endif  // ARM
