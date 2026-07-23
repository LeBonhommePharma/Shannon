// entropy_avx512.cpp — AVX-512 entropy kernels for Shannon 2.0
//
// Compiled with -mavx512f -mavx512dq -mavx512bw only.
// Safe to run on any x86_64 with AVX-512.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
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

static inline double hsum512_pd(__m512d v) noexcept {
    __m256d lo = _mm512_castpd512_pd256(v);
    __m256d hi = _mm512_extractf64x4_pd(v, 1);
    return hsum256_pd(_mm256_add_pd(lo, hi));
}

#if defined(SHANNON_USE_AVX512)

double configurational_entropy_avx512(const double* w, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    __m512d v_max  = _mm512_set1_pd(max_w);
    __m512d acc_Z  = _mm512_setzero_pd();
    __m512d acc_ws = _mm512_setzero_pd();

    std::size_t i = 0;
    for (; i + 7 < n; i += 8) {
        __m512d vw = _mm512_loadu_pd(w + i);
        __m512d sh = _mm512_sub_pd(vw, v_max);
        __m512d ev = simd::shannon_exp_avx512(sh);
        acc_Z  = _mm512_add_pd(acc_Z, ev);
        acc_ws = _mm512_fmadd_pd(sh, ev, acc_ws);
    }

    double Z  = hsum512_pd(acc_Z);
    double ws = hsum512_pd(acc_ws);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_avx512(const double* p, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    __m512d acc = _mm512_setzero_pd();
    std::size_t i = 0;

    for (; i + 7 < n; i += 8) {
        __m512d vp = _mm512_loadu_pd(p + i);
        // contrib = -p * log2(p); zero where p <= kEpsilon (matches scalar).
        __m512d contrib = _mm512_mul_pd(_mm512_sub_pd(_mm512_setzero_pd(), vp),
                                        simd::shannon_log2_avx512(vp));
        __mmask8 m = _mm512_cmp_pd_mask(vp, _mm512_set1_pd(kEpsilon), _CMP_GT_OQ);
        acc = _mm512_add_pd(acc, _mm512_maskz_mov_pd(m, contrib));
    }

    double h = hsum512_pd(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_avx512(const double* lp, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    __m512d acc = _mm512_setzero_pd();
    std::size_t i = 0;

    for (; i + 7 < n; i += 8) {
        __m512d vlp = _mm512_loadu_pd(lp + i);
        __m512d p   = simd::shannon_exp_avx512(vlp);
        // contrib = -p * lp * log2e  (>= 0 since lp <= 0); zero where p <= eps
        __m512d contrib = _mm512_mul_pd(_mm512_mul_pd(p, vlp),
                                        _mm512_set1_pd(-kLog2E));
        __mmask8 m = _mm512_cmp_pd_mask(p, _mm512_set1_pd(kEpsilon), _CMP_GT_OQ);
        acc = _mm512_add_pd(acc, _mm512_maskz_mov_pd(m, contrib));
    }

    double h = hsum512_pd(acc);
    for (; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::fmax(0.0, h);
}

#endif  // SHANNON_USE_AVX512

}  // namespace shannon::kernels

#endif  // x86_64
