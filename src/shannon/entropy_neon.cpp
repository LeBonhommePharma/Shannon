// entropy_neon.cpp — ARM NEON entropy kernels for Shannon 2.0
//
// Compiled for aarch64/ARM with NEON support.
// NOTE: Only configurational_entropy is implemented in NEON. The
// entropy_from_probs and entropy_from_logprobs kernels fall through to
// scalar on NEON platforms. This is intentional — the bottleneck is exp(),
// which has no NEON double-precision intrinsic. Apple Silicon users get
// scalar for the probs/logprobs paths.
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

double configurational_entropy_neon(const double* w, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    float64x2_t v_max  = vdupq_n_f64(max_w);
    float64x2_t acc_Z  = vdupq_n_f64(0.0);
    float64x2_t acc_ws = vdupq_n_f64(0.0);

    std::size_t i = 0;
    for (; i + 1 < n; i += 2) {
        float64x2_t vw = vld1q_f64(w + i);
        float64x2_t sh = vsubq_f64(vw, v_max);
        alignas(16) double sh_arr[2];
        vst1q_f64(sh_arr, sh);
        float64x2_t ev = {std::exp(sh_arr[0]), std::exp(sh_arr[1])};
        acc_Z  = vaddq_f64(acc_Z, ev);
        acc_ws = vaddq_f64(acc_ws, vmulq_f64(sh, ev));
    }

    double Z  = vgetq_lane_f64(acc_Z, 0) + vgetq_lane_f64(acc_Z, 1);
    double ws = vgetq_lane_f64(acc_ws, 0) + vgetq_lane_f64(acc_ws, 1);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

#endif  // SHANNON_USE_NEON

}  // namespace shannon::kernels

#endif  // ARM
