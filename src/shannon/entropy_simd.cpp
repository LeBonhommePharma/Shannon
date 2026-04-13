// entropy_simd.cpp — SIMD-accelerated entropy kernels for Shannon 2.0
//
// Explicit AVX-512, AVX2, SSE4.2, NEON, and OpenMP variants of the
// log-sum-exp configurational entropy kernel, plus probability and
// log-probability entropy variants.
//
// Pattern ported from FlexAIDdS simd_distance.h intrinsics structure.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>

// ── SIMD headers ─────────────────────────────────────────────────────────────
#if defined(__x86_64__) || defined(_M_X64)
#  include <immintrin.h>
#endif

#if defined(__ARM_NEON) || defined(__aarch64__)
#  include <arm_neon.h>
#endif

namespace shannon::kernels {

// ─── Horizontal sum helpers ──────────────────────────────────────────────────

#if defined(__x86_64__) || defined(_M_X64)

static inline double hsum256_pd(__m256d v) noexcept {
    __m128d lo = _mm256_castpd256_pd128(v);
    __m128d hi = _mm256_extractf128_pd(v, 1);
    lo = _mm_add_pd(lo, hi);            // [0+2, 1+3]
    lo = _mm_add_sd(lo, _mm_unpackhi_pd(lo, lo));  // [0+2+1+3]
    return _mm_cvtsd_f64(lo);
}

static inline double hsum128_pd(__m128d v) noexcept {
    __m128d hi = _mm_unpackhi_pd(v, v);
    __m128d s  = _mm_add_sd(v, hi);
    return _mm_cvtsd_f64(s);
}

#if defined(__AVX512F__)
static inline double hsum512_pd(__m512d v) noexcept {
    __m256d lo = _mm512_castpd512_pd256(v);
    __m256d hi = _mm512_extractf64x4_pd(v, 1);
    return hsum256_pd(_mm256_add_pd(lo, hi));
}
#endif

#endif  // x86

// ─── OpenMP variant ──────────────────────────────────────────────────────────

#if defined(SHANNON_USE_OPENMP)

double configurational_entropy_omp(const double* w, std::size_t n) {
    if (n <= 1) return 0.0;

    double max_w = w[0];
    #pragma omp simd reduction(max:max_w)
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    double Z = 0.0;
    double ws = 0.0;

    #pragma omp parallel for simd reduction(+:Z,ws) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::max(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_omp(const double* p, std::size_t n) {
    if (n == 0) return 0.0;
    double h = 0.0;
    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::max(0.0, h);
}

double entropy_from_logprobs_omp(const double* lp, std::size_t n) {
    if (n == 0) return 0.0;
    double h = 0.0;
    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::max(0.0, h);
}

#endif  // SHANNON_USE_OPENMP

// ─── SSE4.2 variant (2 doubles at a time) ────────────────────────────────────

#if defined(SHANNON_USE_SSE42) && (defined(__x86_64__) || defined(_M_X64))

double configurational_entropy_sse42(const double* w, std::size_t n) {
    if (n <= 1) return 0.0;

    // Step 1: find max
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
        // Scalar exp for each element (SSE has no exp instruction)
        alignas(16) double sh_arr[2];
        _mm_store_pd(sh_arr, sh);
        __m128d ev = _mm_set_pd(std::exp(sh_arr[1]), std::exp(sh_arr[0]));
        acc_Z  = _mm_add_pd(acc_Z, ev);
        acc_ws = _mm_add_pd(acc_ws, _mm_mul_pd(sh, ev));
    }

    double Z  = hsum128_pd(acc_Z);
    double ws = hsum128_pd(acc_ws);

    // Scalar tail
    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::max(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

#endif  // SSE4.2

// ─── AVX2 variant (4 doubles at a time) ──────────────────────────────────────

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))

double configurational_entropy_avx2(const double* w, std::size_t n) {
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
        // Scalar exp for each element
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

    // Scalar tail
    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::max(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_avx2(const double* p, std::size_t n) {
    if (n == 0) return 0.0;

    __m256d acc = _mm256_setzero_pd();
    std::size_t i = 0;

    for (; i + 3 < n; i += 4) {
        alignas(32) double p_arr[4];
        _mm256_store_pd(p_arr, _mm256_loadu_pd(p + i));
        // Scalar log2 per element
        __m256d vp = _mm256_loadu_pd(p + i);
        // Mask: only compute where p > epsilon
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
    return std::max(0.0, h);
}

double entropy_from_logprobs_avx2(const double* lp, std::size_t n) {
    if (n == 0) return 0.0;

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
    return std::max(0.0, h);
}

#endif  // AVX2

// ─── AVX-512 variant (8 doubles at a time) ───────────────────────────────────

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))

double configurational_entropy_avx512(const double* w, std::size_t n) {
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
        // Scalar exp (no SVML guarantee)
        alignas(64) double sh_arr[8];
        _mm512_store_pd(sh_arr, sh);
        __m512d ev = _mm512_set_pd(
            std::exp(sh_arr[7]), std::exp(sh_arr[6]),
            std::exp(sh_arr[5]), std::exp(sh_arr[4]),
            std::exp(sh_arr[3]), std::exp(sh_arr[2]),
            std::exp(sh_arr[1]), std::exp(sh_arr[0]));
        acc_Z  = _mm512_add_pd(acc_Z, ev);
        acc_ws = _mm512_fmadd_pd(sh, ev, acc_ws);
    }

    double Z  = hsum512_pd(acc_Z);
    double ws = hsum512_pd(acc_ws);

    // Scalar tail
    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::max(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_avx512(const double* p, std::size_t n) {
    if (n == 0) return 0.0;

    __m512d acc = _mm512_setzero_pd();
    std::size_t i = 0;

    for (; i + 7 < n; i += 8) {
        alignas(64) double p_arr[8];
        _mm512_store_pd(p_arr, _mm512_loadu_pd(p + i));
        alignas(64) double contrib[8];
        for (int k = 0; k < 8; ++k) {
            contrib[k] = (p_arr[k] > kEpsilon) ? -p_arr[k] * std::log2(p_arr[k]) : 0.0;
        }
        acc = _mm512_add_pd(acc, _mm512_load_pd(contrib));
    }

    double h = hsum512_pd(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::max(0.0, h);
}

double entropy_from_logprobs_avx512(const double* lp, std::size_t n) {
    if (n == 0) return 0.0;

    __m512d acc = _mm512_setzero_pd();
    std::size_t i = 0;

    for (; i + 7 < n; i += 8) {
        alignas(64) double lp_arr[8];
        _mm512_store_pd(lp_arr, _mm512_loadu_pd(lp + i));
        alignas(64) double contrib[8];
        for (int k = 0; k < 8; ++k) {
            double p = std::exp(lp_arr[k]);
            contrib[k] = (p > kEpsilon) ? -p * lp_arr[k] * kLog2E : 0.0;
        }
        acc = _mm512_add_pd(acc, _mm512_load_pd(contrib));
    }

    double h = hsum512_pd(acc);
    for (; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::max(0.0, h);
}

#endif  // AVX-512

// ─── NEON variant (2 doubles at a time, ARM) ─────────────────────────────────

#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))

double configurational_entropy_neon(const double* w, std::size_t n) {
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
        // Scalar exp
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
    return std::max(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

#endif  // NEON

}  // namespace shannon::kernels
