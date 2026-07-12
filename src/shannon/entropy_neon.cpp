// entropy_neon.cpp — ARM NEON entropy kernels for Shannon 2.0
//
// Compiled for aarch64/ARM with NEON (ASIMD). Implements all three entropy
// entry points so UnifiedDispatch can keep NEON as the default CPU backend
// on Apple Silicon and other aarch64 hosts.
//
// Note: NEON has no double-precision exp/log intrinsics, so transcendental
// calls remain scalar. Vectorization still pays off via load/store, fused
// multiply-add of shifted*exp, and vmax reductions for log-sum-exp max.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>

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

// Load two scalar exp results into a float64x2_t without compound literals
[[nodiscard]] inline float64x2_t load_exp_pair(double a, double b) noexcept {
    alignas(16) double buf[2] = {a, b};
    return vld1q_f64(buf);
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
        float64x2_t vw0 = vld1q_f64(w + i);
        float64x2_t vw1 = vld1q_f64(w + i + 2);
        float64x2_t sh0 = vsubq_f64(vw0, v_max);
        float64x2_t sh1 = vsubq_f64(vw1, v_max);

        alignas(16) double sh0_arr[2], sh1_arr[2];
        vst1q_f64(sh0_arr, sh0);
        vst1q_f64(sh1_arr, sh1);

        float64x2_t ev0 = load_exp_pair(std::exp(sh0_arr[0]), std::exp(sh0_arr[1]));
        float64x2_t ev1 = load_exp_pair(std::exp(sh1_arr[0]), std::exp(sh1_arr[1]));

        acc_Z  = vaddq_f64(acc_Z, ev0);
        acc_Z  = vaddq_f64(acc_Z, ev1);
        acc_ws = vfmaq_f64(acc_ws, sh0, ev0);  // acc += sh * exp(sh)
        acc_ws = vfmaq_f64(acc_ws, sh1, ev1);
    }

    for (; i + 1 < n; i += 2) {
        float64x2_t vw = vld1q_f64(w + i);
        float64x2_t sh = vsubq_f64(vw, v_max);
        alignas(16) double sh_arr[2];
        vst1q_f64(sh_arr, sh);
        float64x2_t ev = load_exp_pair(std::exp(sh_arr[0]), std::exp(sh_arr[1]));
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

    float64x2_t acc = vdupq_n_f64(0.0);
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        alignas(16) double p0[2], p1[2];
        vst1q_f64(p0, vld1q_f64(p + i));
        vst1q_f64(p1, vld1q_f64(p + i + 2));
        alignas(16) double c0[2], c1[2];
        for (int k = 0; k < 2; ++k) {
            c0[k] = (p0[k] > kEpsilon) ? -p0[k] * std::log2(p0[k]) : 0.0;
            c1[k] = (p1[k] > kEpsilon) ? -p1[k] * std::log2(p1[k]) : 0.0;
        }
        acc = vaddq_f64(acc, vld1q_f64(c0));
        acc = vaddq_f64(acc, vld1q_f64(c1));
    }

    for (; i + 1 < n; i += 2) {
        alignas(16) double p_arr[2];
        vst1q_f64(p_arr, vld1q_f64(p + i));
        alignas(16) double contrib[2];
        for (int k = 0; k < 2; ++k) {
            contrib[k] = (p_arr[k] > kEpsilon) ? -p_arr[k] * std::log2(p_arr[k]) : 0.0;
        }
        acc = vaddq_f64(acc, vld1q_f64(contrib));
    }

    double h = hsum_f64x2(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_neon(const double* lp, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    float64x2_t acc = vdupq_n_f64(0.0);
    const float64x2_t v_log2e = vdupq_n_f64(kLog2E);
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        alignas(16) double lp0[2], lp1[2];
        vst1q_f64(lp0, vld1q_f64(lp + i));
        vst1q_f64(lp1, vld1q_f64(lp + i + 2));
        alignas(16) double c0[2], c1[2];
        for (int k = 0; k < 2; ++k) {
            const double p0 = std::exp(lp0[k]);
            const double p1 = std::exp(lp1[k]);
            c0[k] = (p0 > kEpsilon) ? -p0 * lp0[k] : 0.0;
            c1[k] = (p1 > kEpsilon) ? -p1 * lp1[k] : 0.0;
        }
        // scale nats → bits with NEON multiply
        float64x2_t vc0 = vmulq_f64(vld1q_f64(c0), v_log2e);
        float64x2_t vc1 = vmulq_f64(vld1q_f64(c1), v_log2e);
        acc = vaddq_f64(acc, vc0);
        acc = vaddq_f64(acc, vc1);
    }

    for (; i + 1 < n; i += 2) {
        alignas(16) double lp_arr[2];
        vst1q_f64(lp_arr, vld1q_f64(lp + i));
        alignas(16) double contrib[2];
        for (int k = 0; k < 2; ++k) {
            const double p = std::exp(lp_arr[k]);
            contrib[k] = (p > kEpsilon) ? -p * lp_arr[k] : 0.0;
        }
        acc = vaddq_f64(acc, vmulq_f64(vld1q_f64(contrib), v_log2e));
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
