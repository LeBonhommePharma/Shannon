// entropy_avx512.cpp — AVX-512 entropy kernels for Shannon 2.0
//
// Compiled with -mavx512f -mavx512dq -mavx512bw only.
// Safe to run on any x86_64 with AVX-512.
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

static inline double hsum512_pd(__m512d v) noexcept {
    __m256d lo = _mm512_castpd512_pd256(v);
    __m256d hi = _mm512_extractf64x4_pd(v, 1);
    return hsum256_pd(_mm256_add_pd(lo, hi));
}

#if defined(SHANNON_USE_AVX512)

namespace {

struct Avx512Traits {
    using vec = __m512d;
    static constexpr std::size_t width = 8;

    [[nodiscard]] static vec set1(double x) noexcept { return _mm512_set1_pd(x); }
    [[nodiscard]] static vec zero() noexcept { return _mm512_setzero_pd(); }
    [[nodiscard]] static vec load(const double* p) noexcept { return _mm512_loadu_pd(p); }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return _mm512_sub_pd(a, b); }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return _mm512_add_pd(a, b); }
    [[nodiscard]] static vec mul(vec a, vec b) noexcept { return _mm512_mul_pd(a, b); }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept {
        return _mm512_fmadd_pd(a, b, c);
    }
    [[nodiscard]] static vec exp(vec x) noexcept { return simd::shannon_exp_avx512(x); }
    [[nodiscard]] static vec log2(vec x) noexcept { return simd::shannon_log2_avx512(x); }
    [[nodiscard]] static vec select_gt(vec values, double threshold, vec if_true) noexcept {
        const __mmask8 m =
            _mm512_cmp_pd_mask(values, _mm512_set1_pd(threshold), _CMP_GT_OQ);
        return _mm512_maskz_mov_pd(m, if_true);
    }
    [[nodiscard]] static vec select_finite(vec x, vec v) noexcept {
        const vec ax = _mm512_andnot_pd(_mm512_set1_pd(-0.0), x);
        const __mmask8 m = _mm512_cmp_pd_mask(
            ax, _mm512_set1_pd(std::numeric_limits<double>::infinity()), _CMP_LT_OQ);
        return _mm512_maskz_mov_pd(m, v);
    }
    [[nodiscard]] static double hsum(vec v) noexcept { return hsum512_pd(v); }
};

}  // namespace

double configurational_entropy_avx512(std::span<const double> weights) noexcept {
    return configurational_entropy<Avx512Traits>(weights);
}

double entropy_from_probs_avx512(std::span<const double> probs) noexcept {
    return entropy_from_probs<Avx512Traits>(probs);
}

double entropy_from_logprobs_avx512(std::span<const double> logprobs) noexcept {
    return entropy_from_logprobs<Avx512Traits>(logprobs);
}

#endif  // SHANNON_USE_AVX512

}  // namespace shannon::kernels

#endif  // x86_64
