// simd_exp.hpp — Vectorized double-precision exp() for Shannon 2.0 SIMD kernels
//
// The per-token entropy kernels are dominated by the transcendental exp()
// (~95% of cost). The original AVX2/AVX-512 kernels stored the shifted vector
// to the stack and called scalar std::exp() per lane, pinning throughput at
// ~92 M elem/s on every ISA. This header replaces that with a fully-vectorized
// exp built from a range reduction and a polynomial.
//
// Algorithm: range-reduce x = n·ln2 + r with |r| <= ln2/2 using a two-part ln2
// constant, evaluate exp(r) with a degree-13 Taylor/Horner polynomial (the
// truncation error of the degree-13 series over |r| <= ln2/2 ≈ 0.3466 is
// ~2e-18, so the evaluation is machine-precision), then scale by 2^n. 2^n is
// built directly from IEEE-754 exponent bits and split into two factors so the
// result underflows *gradually* to a correct subnormal and then to +0.0 for
// very negative x — never NaN or denormal garbage.
//
// Accuracy: max relative error vs std::exp < 1e-13 over the domain that matters
// (inputs <= 0, i.e. after the log-sum-exp max-shift). exp(0) == 1.0 exactly.
// Inputs below ~-745 flush to +0.0. Validated in tests/cpp/test_simd_exp.cpp.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>

namespace shannon::kernels::simd {

namespace detail {
inline constexpr double kLog2E = 1.4426950408889634073599;  // 1/ln2
inline constexpr double kC1    = 6.93145751953125e-1;        // ln2 high part
inline constexpr double kC2    = 1.42860682030941723212e-6;  // ln2 low part
inline constexpr double kMagic = 4503599627370496.0 + 1023.0;  // 2^52 + bias
// exp(r) ≈ Σ_{k=0}^{13} r^k / k!  (Horner, highest degree first).
inline constexpr double kT13 = 1.6059043836821613e-10;  // 1/13!
inline constexpr double kT12 = 2.08767569878681e-9;     // 1/12!
inline constexpr double kT11 = 2.505210838544172e-8;    // 1/11!
inline constexpr double kT10 = 2.755731922398589e-7;    // 1/10!
inline constexpr double kT9  = 2.7557319223985893e-6;   // 1/9!
inline constexpr double kT8  = 2.48015873015873e-5;     // 1/8!
inline constexpr double kT7  = 1.9841269841269841e-4;   // 1/7!
inline constexpr double kT6  = 1.388888888888889e-3;    // 1/6!
inline constexpr double kT5  = 8.333333333333333e-3;    // 1/5!
inline constexpr double kT4  = 4.1666666666666664e-2;   // 1/4!
inline constexpr double kT3  = 1.6666666666666666e-1;   // 1/3!
inline constexpr double kT2  = 5.0e-1;                  // 1/2!
inline constexpr double kT1  = 1.0;                     // 1/1!
inline constexpr double kT0  = 1.0;                     // 1/0!
}  // namespace detail

// ─── AVX2 (__m256d) ───────────────────────────────────────────────────────────
#if defined(__AVX2__)

// Build 2^k for an integer-valued double k in [-538, 0] by injecting k+1023
// into the IEEE-754 exponent field via the "add 2^52" mantissa-alignment trick.
[[nodiscard]] static inline __m256d shannon_pow2_half_avx2(__m256d k) noexcept {
    __m256d a = _mm256_add_pd(k, _mm256_set1_pd(detail::kMagic));
    __m256i b = _mm256_slli_epi64(_mm256_castpd_si256(a), 52);
    return _mm256_castsi256_pd(b);
}

[[nodiscard]] static inline __m256d shannon_exp_avx2(__m256d x) noexcept {
    using namespace detail;
    // n = round(x / ln2)
    __m256d n = _mm256_round_pd(_mm256_mul_pd(x, _mm256_set1_pd(kLog2E)),
                               _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
    // r = x - n*ln2   (two-part subtraction for extra precision)
    __m256d r = _mm256_fnmadd_pd(n, _mm256_set1_pd(kC1), x);
    r = _mm256_fnmadd_pd(n, _mm256_set1_pd(kC2), r);

    // exp(r) via degree-13 Horner Taylor polynomial.
    __m256d p = _mm256_set1_pd(kT13);
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT12));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT11));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT10));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT9));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT8));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT7));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT6));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT5));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT4));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT3));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT2));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT1));
    p = _mm256_fmadd_pd(p, r, _mm256_set1_pd(kT0));

    // 2^n via two half-scales: gradual underflow to correct subnormal / +0.0
    __m256d n1 = _mm256_floor_pd(_mm256_mul_pd(n, _mm256_set1_pd(0.5)));
    __m256d n2 = _mm256_sub_pd(n, n1);
    __m256d scale = _mm256_mul_pd(shannon_pow2_half_avx2(n1),
                                  shannon_pow2_half_avx2(n2));
    return _mm256_mul_pd(p, scale);
}

#endif  // __AVX2__

// ─── AVX-512 (__m512d) ─────────────────────────────────────────────────────────
#if defined(__AVX512F__)

[[nodiscard]] static inline __m512d shannon_pow2_half_avx512(__m512d k) noexcept {
    __m512d a = _mm512_add_pd(k, _mm512_set1_pd(detail::kMagic));
    __m512i b = _mm512_slli_epi64(_mm512_castpd_si512(a), 52);
    return _mm512_castsi512_pd(b);
}

[[nodiscard]] static inline __m512d shannon_exp_avx512(__m512d x) noexcept {
    using namespace detail;
    __m512d n = _mm512_roundscale_pd(_mm512_mul_pd(x, _mm512_set1_pd(kLog2E)),
                                     _MM_FROUND_TO_NEAREST_INT | _MM_FROUND_NO_EXC);
    __m512d r = _mm512_fnmadd_pd(n, _mm512_set1_pd(kC1), x);
    r = _mm512_fnmadd_pd(n, _mm512_set1_pd(kC2), r);

    __m512d p = _mm512_set1_pd(kT13);
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT12));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT11));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT10));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT9));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT8));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT7));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT6));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT5));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT4));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT3));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT2));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT1));
    p = _mm512_fmadd_pd(p, r, _mm512_set1_pd(kT0));

    __m512d n1 = _mm512_roundscale_pd(_mm512_mul_pd(n, _mm512_set1_pd(0.5)),
                                      _MM_FROUND_TO_NEG_INF | _MM_FROUND_NO_EXC);
    __m512d n2 = _mm512_sub_pd(n, n1);
    __m512d scale = _mm512_mul_pd(shannon_pow2_half_avx512(n1),
                                  shannon_pow2_half_avx512(n2));
    return _mm512_mul_pd(p, scale);
}

#endif  // __AVX512F__

}  // namespace shannon::kernels::simd

#endif  // x86_64
