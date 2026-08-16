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

#include <algorithm>
#include <cmath>
#include <cstddef>

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

// AVX2 vector traits for configurational_entropy<>. Instantiated only in this
// TU (compiled with -mavx2 -mfma). Probs/logprobs kernels stay hand-written.
struct Avx2Traits {
    using vec = __m256d;
    static constexpr std::size_t width = 4;

    [[nodiscard]] static vec set1(double x) noexcept { return _mm256_set1_pd(x); }
    [[nodiscard]] static vec zero() noexcept { return _mm256_setzero_pd(); }
    [[nodiscard]] static vec load(const double* p) noexcept { return _mm256_loadu_pd(p); }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return _mm256_sub_pd(a, b); }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return _mm256_add_pd(a, b); }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept {
        return _mm256_fmadd_pd(a, b, c);
    }
    [[nodiscard]] static vec exp(vec x) noexcept { return simd::shannon_exp_avx2(x); }
    [[nodiscard]] static double hsum(vec v) noexcept { return hsum256_pd(v); }
};

}  // namespace

double configurational_entropy_avx2(std::span<const double> weights) noexcept {
    return configurational_entropy<Avx2Traits>(weights);
}

double entropy_from_probs_avx2(std::span<const double> probs) noexcept {
    const double* p = probs.data();
    const std::size_t n = probs.size();
    if (n <= 1) return 0.0;

    __m256d acc = _mm256_setzero_pd();
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        __m256d vp = _mm256_loadu_pd(p + i);
        // contrib = -p * log2(p); zero where p <= kEpsilon (matches scalar).
        __m256d contrib = _mm256_mul_pd(_mm256_sub_pd(_mm256_setzero_pd(), vp),
                                        simd::shannon_log2_avx2(vp));
        __m256d m = _mm256_cmp_pd(vp, _mm256_set1_pd(kEpsilon), _CMP_GT_OQ);
        acc = _mm256_add_pd(acc, _mm256_and_pd(m, contrib));
    }

    double h = hsum256_pd(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_avx2(std::span<const double> logprobs) noexcept {
    const double* lp = logprobs.data();
    const std::size_t n = logprobs.size();
    if (n <= 1) return 0.0;

    __m256d acc = _mm256_setzero_pd();
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        __m256d vlp = _mm256_loadu_pd(lp + i);
        __m256d p   = simd::shannon_exp_avx2(vlp);
        // contrib = -p * lp * log2e  (>= 0 since lp <= 0); zero where p <= eps
        __m256d contrib = _mm256_mul_pd(_mm256_mul_pd(p, vlp),
                                        _mm256_set1_pd(-kLog2E));
        __m256d m = _mm256_cmp_pd(p, _mm256_set1_pd(kEpsilon), _CMP_GT_OQ);
        acc = _mm256_add_pd(acc, _mm256_and_pd(m, contrib));
    }

    double h = hsum256_pd(acc);
    for (; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::fmax(0.0, h);
}

#endif  // SHANNON_USE_AVX2

}  // namespace shannon::kernels

#endif  // x86_64
