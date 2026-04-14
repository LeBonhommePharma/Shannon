// entropy_avx2.cpp — AVX2+FMA entropy kernels for Shannon 2.0
//
// Compiled with -mavx2 -mfma only. Safe to run on any x86_64 with AVX2.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

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

double configurational_entropy_avx2(const double* w, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    __m256d v_max = _mm256_set1_pd(max_w);
    __m256d acc_Z = _mm256_setzero_pd();
    __m256d acc_ws = _mm256_setzero_pd();

    std::size_t i = 0;
    for (; i + 3 < n; i += 4) {
        __m256d vw = _mm256_loadu_pd(w + i);
        __m256d sh = _mm256_sub_pd(vw, v_max);
        alignas(32) double sh_arr[4];
        _mm256_store_pd(sh_arr, sh);
        __m256d ev = _mm256_set_pd(
            std::exp(sh_arr[3]), std::exp(sh_arr[2]),
            std::exp(sh_arr[1]), std::exp(sh_arr[0]));
        acc_Z  = _mm256_add_pd(acc_Z, ev);
        acc_ws = _mm256_fmadd_pd(sh, ev, acc_ws);
    }

    double Z  = hsum256_pd(acc_Z);
    double ws = hsum256_pd(acc_ws);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_avx2(const double* p, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    __m256d acc = _mm256_setzero_pd();
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        alignas(32) double p_arr[4];
        _mm256_store_pd(p_arr, _mm256_loadu_pd(p + i));
        alignas(32) double log_arr[4];
        for (int k = 0; k < 4; ++k) {
            log_arr[k] = (p_arr[k] > kEpsilon) ? -p_arr[k] * std::log2(p_arr[k]) : 0.0;
        }
        acc = _mm256_add_pd(acc, _mm256_load_pd(log_arr));
    }

    double h = hsum256_pd(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_avx2(const double* lp, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    __m256d acc = _mm256_setzero_pd();
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        alignas(32) double lp_arr[4];
        _mm256_store_pd(lp_arr, _mm256_loadu_pd(lp + i));
        alignas(32) double contrib[4];
        for (int k = 0; k < 4; ++k) {
            double p = std::exp(lp_arr[k]);
            contrib[k] = (p > kEpsilon) ? -p * lp_arr[k] * kLog2E : 0.0;
        }
        acc = _mm256_add_pd(acc, _mm256_load_pd(contrib));
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
