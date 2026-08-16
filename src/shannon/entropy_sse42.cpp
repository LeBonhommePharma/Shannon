// entropy_sse42.cpp — SSE4.2 entropy kernels for Shannon 2.0
//
// Compiled with -msse4.2 only. Safe to run on any x86_64 with SSE4.2.
// No FMA and no vector exp — Traits::exp is libm per lane; fmadd is mul+add.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/entropy_algorithm.hpp"
#include "shannon/config.hpp"

#include <cmath>
#include <cstddef>
#include <limits>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>

namespace shannon::kernels {

#if defined(SHANNON_USE_SSE42)

namespace {

static inline double hsum128_pd(__m128d v) noexcept {
    __m128d hi = _mm_unpackhi_pd(v, v);
    __m128d s = _mm_add_sd(v, hi);
    return _mm_cvtsd_f64(s);
}

struct Sse42Traits {
    using vec = __m128d;
    static constexpr std::size_t width = 2;

    [[nodiscard]] static vec set1(double x) noexcept { return _mm_set1_pd(x); }
    [[nodiscard]] static vec zero() noexcept { return _mm_setzero_pd(); }
    [[nodiscard]] static vec load(const double* p) noexcept { return _mm_loadu_pd(p); }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return _mm_sub_pd(a, b); }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return _mm_add_pd(a, b); }
    [[nodiscard]] static vec mul(vec a, vec b) noexcept { return _mm_mul_pd(a, b); }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept {
        return _mm_add_pd(_mm_mul_pd(a, b), c);
    }
    [[nodiscard]] static vec exp(vec x) noexcept {
        alignas(16) double sh_arr[2];
        _mm_store_pd(sh_arr, x);
        return _mm_set_pd(std::exp(sh_arr[1]), std::exp(sh_arr[0]));
    }
    [[nodiscard]] static vec select_finite(vec x, vec v) noexcept {
        const vec ax = _mm_andnot_pd(_mm_set1_pd(-0.0), x);
        const vec m =
            _mm_cmplt_pd(ax, _mm_set1_pd(std::numeric_limits<double>::infinity()));
        return _mm_and_pd(m, v);
    }
    [[nodiscard]] static double hsum(vec v) noexcept { return hsum128_pd(v); }
};

}  // namespace

double configurational_entropy_sse42(std::span<const double> weights) noexcept {
    return configurational_entropy<Sse42Traits>(weights);
}

#endif  // SHANNON_USE_SSE42

}  // namespace shannon::kernels

#endif  // x86_64
