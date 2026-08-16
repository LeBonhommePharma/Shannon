// entropy_avx2.cpp — AVX2+FMA entropy kernels for Shannon 2.0
//
// Compiled with -mavx2 -mfma only. Safe to run on any x86_64 with AVX2.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/entropy_algorithm.hpp"
#include "shannon/config.hpp"
#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"

#include <cmath>
#include <cstddef>
#include <limits>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>

namespace shannon::kernels {

static inline double hsum256_pd(__m256d v) noexcept {
    __m128d lo = _mm256_castpd256_pd128(v);
    __m128d hi = _mm256_extractf128_pd(v, 1);
    lo = _mm_add_pd(lo, hi);
    lo = _mm_add_sd(lo, _mm_unpackhi_pd(lo, lo));
    return _mm_cvtsd_f64(lo);
}

#if defined(SHANNON_USE_AVX2)

namespace {

struct Avx2Traits {
    using vec = __m256d;
    static constexpr std::size_t width = 4;

    [[nodiscard]] static vec set1(double x) noexcept { return _mm256_set1_pd(x); }
    [[nodiscard]] static vec zero() noexcept { return _mm256_setzero_pd(); }
    [[nodiscard]] static vec load(const double* p) noexcept { return _mm256_loadu_pd(p); }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return _mm256_sub_pd(a, b); }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return _mm256_add_pd(a, b); }
    [[nodiscard]] static vec mul(vec a, vec b) noexcept { return _mm256_mul_pd(a, b); }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept {
        return _mm256_fmadd_pd(a, b, c);
    }
    [[nodiscard]] static vec exp(vec x) noexcept { return simd::shannon_exp_avx2(x); }
    [[nodiscard]] static vec log2(vec x) noexcept { return simd::shannon_log2_avx2(x); }
    [[nodiscard]] static vec select_gt(vec values, double threshold, vec if_true) noexcept {
        const vec m = _mm256_cmp_pd(values, _mm256_set1_pd(threshold), _CMP_GT_OQ);
        return _mm256_and_pd(m, if_true);
    }
    [[nodiscard]] static vec select_finite(vec x, vec v) noexcept {
        const vec ax = _mm256_andnot_pd(_mm256_set1_pd(-0.0), x);
        const vec m = _mm256_cmp_pd(
            ax, _mm256_set1_pd(std::numeric_limits<double>::infinity()), _CMP_LT_OQ);
        return _mm256_and_pd(m, v);
    }
    [[nodiscard]] static double hsum(vec v) noexcept { return hsum256_pd(v); }
};

}  // namespace

double configurational_entropy_avx2(std::span<const double> weights) noexcept {
    return configurational_entropy<Avx2Traits>(weights);
}

double entropy_from_probs_avx2(std::span<const double> probs) noexcept {
    return entropy_from_probs<Avx2Traits>(probs);
}

double entropy_from_logprobs_avx2(std::span<const double> logprobs) noexcept {
    return entropy_from_logprobs<Avx2Traits>(logprobs);
}

#endif  // SHANNON_USE_AVX2

}  // namespace shannon::kernels

#endif  // x86_64
