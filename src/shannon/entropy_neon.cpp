// entropy_neon.cpp — ARM NEON entropy kernels for Shannon 2.0
//
// Compiled for aarch64/ARM with NEON (ASIMD). Implements all three entropy
// entry points so UnifiedDispatch can keep NEON as the default CPU backend
// on Apple Silicon and other aarch64 hosts.
//
// The transcendentals are fully vectorized via shannon_exp_neon /
// shannon_log2_neon (simd_exp.hpp / simd_log2.hpp) — the same range-reduced
// polynomial kernels used by the AVX2/AVX-512 paths, ported to float64x2_t.
// Instantiated through entropy_algorithm.hpp (width=2). The previous 4-wide
// ILP unroll is the same pair-add association as two width-2 steps.
// Validated under qemu-aarch64 (scripts/test_neon_qemu.sh) and runnable
// natively on Apple Silicon via the same harness.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/entropy_algorithm.hpp"
#include "shannon/config.hpp"

#include <cmath>
#include <cstddef>
#include <limits>

#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>

#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"

namespace shannon::kernels {

#if defined(SHANNON_USE_NEON)

namespace {

[[nodiscard]] inline double hsum_f64x2(float64x2_t v) noexcept {
    return vgetq_lane_f64(v, 0) + vgetq_lane_f64(v, 1);
}

struct NeonTraits {
    using vec = float64x2_t;
    static constexpr std::size_t width = 2;

    [[nodiscard]] static vec set1(double x) noexcept { return vdupq_n_f64(x); }
    [[nodiscard]] static vec zero() noexcept { return vdupq_n_f64(0.0); }
    [[nodiscard]] static vec load(const double* p) noexcept { return vld1q_f64(p); }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return vsubq_f64(a, b); }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return vaddq_f64(a, b); }
    [[nodiscard]] static vec mul(vec a, vec b) noexcept { return vmulq_f64(a, b); }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept {
        return vfmaq_f64(c, a, b);  // c + a*b
    }
    [[nodiscard]] static vec exp(vec x) noexcept { return simd::shannon_exp_neon(x); }
    [[nodiscard]] static vec log2(vec x) noexcept { return simd::shannon_log2_neon(x); }
    [[nodiscard]] static vec select_gt(vec values, double threshold, vec if_true) noexcept {
        const uint64x2_t m = vcgtq_f64(values, vdupq_n_f64(threshold));
        return vbslq_f64(m, if_true, vdupq_n_f64(0.0));
    }
    [[nodiscard]] static vec select_finite(vec x, vec v) noexcept {
        const uint64x2_t m =
            vcltq_f64(vabsq_f64(x), vdupq_n_f64(std::numeric_limits<double>::infinity()));
        return vbslq_f64(m, v, vdupq_n_f64(0.0));
    }
    [[nodiscard]] static double hsum(vec v) noexcept { return hsum_f64x2(v); }
};

}  // namespace

double configurational_entropy_neon(std::span<const double> weights) noexcept {
    return configurational_entropy<NeonTraits>(weights);
}

double entropy_from_probs_neon(std::span<const double> probs) noexcept {
    return entropy_from_probs<NeonTraits>(probs);
}

double entropy_from_logprobs_neon(std::span<const double> logprobs) noexcept {
    return entropy_from_logprobs<NeonTraits>(logprobs);
}

#endif  // SHANNON_USE_NEON

}  // namespace shannon::kernels

#endif  // ARM
