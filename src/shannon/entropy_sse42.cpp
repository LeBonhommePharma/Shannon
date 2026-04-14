// entropy_sse42.cpp — SSE4.2 entropy kernels for Shannon 2.0
//
// Compiled with -msse4.2 only. Safe to run on any x86_64 with SSE4.2.
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

#if defined(SHANNON_USE_SSE42)

static inline double hsum128_pd(__m128d v) noexcept {
    __m128d hi = _mm_unpackhi_pd(v, v);
    __m128d s  = _mm_add_sd(v, hi);
    return _mm_cvtsd_f64(s);
}

double configurational_entropy_sse42(const double* w, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    __m128d v_max = _mm_set1_pd(max_w);
    __m128d acc_Z = _mm_setzero_pd();
    __m128d acc_ws = _mm_setzero_pd();

    std::size_t i = 0;
    for (; i + 1 < n; i += 2) {
        __m128d vw  = _mm_loadu_pd(w + i);
        __m128d sh  = _mm_sub_pd(vw, v_max);
        alignas(16) double sh_arr[2];
        _mm_store_pd(sh_arr, sh);
        __m128d ev = _mm_set_pd(std::exp(sh_arr[1]), std::exp(sh_arr[0]));
        acc_Z  = _mm_add_pd(acc_Z, ev);
        acc_ws = _mm_add_pd(acc_ws, _mm_mul_pd(sh, ev));
    }

    double Z  = hsum128_pd(acc_Z);
    double ws = hsum128_pd(acc_ws);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

#endif  // SHANNON_USE_SSE42

}  // namespace shannon::kernels

#endif  // x86_64
