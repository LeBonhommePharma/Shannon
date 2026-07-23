// simd_log2.hpp — Vectorized double-precision log2() for Shannon 2.0 SIMD kernels
//
// The entropy-from-probs kernels compute H = -Σ p·log2(p). After the exp() in
// the logits/logprobs kernels was vectorized (simd_exp.hpp), the probs kernels
// were the last SIMD loops still calling a scalar transcendental — std::log2()
// per lane inside the vector loop — pinning them at scalar-libm throughput.
// This header replaces that with a fully-vectorized log2.
//
// Decision: in-house polynomial, not SLEEF. SLEEF is not present on the build
// box (no system package, no header) and pulling a whole vector-math library in
// via FetchContent for a single 8-lane log2 is a large dependency for ~40 lines
// of code; the repo already ships an in-house simd_exp.hpp with its own gtest
// accuracy suite, so an in-house simd_log2 keeps the two transcendentals
// consistent, self-contained, and testable with the same harness.
//
// Algorithm: decompose x = m · 2^e from the IEEE-754 bits (e from the exponent
// field, m ∈ [1,2) from the mantissa), then reduce m into [√½, √2) so the
// argument of the series is centred on 1. Write log(m) with the odd atanh
// series log(m) = 2·(s + s³/3 + s⁵/5 + …) where s = (m-1)/(m+1) ∈ [-0.172, 0.172];
// with |s²| ≤ 0.0295 a degree-15 (8-term) series is machine-precision. Finally
// log2(x) = e + log2(e)·log(m).
//
// Accuracy: max relative error vs std::log2 < 1e-12 over p ∈ (1e-300, 1].
// log2(1) == 0 exactly (m == 1 ⇒ s == 0 ⇒ series == 0, e == 0). Inputs are
// assumed strictly positive and normal (p > kEpsilon = 1e-300); the entropy
// kernels mask p ≤ kEpsilon to a 0.0 contribution before/after this call, so
// zero/subnormal/negative lanes never need a meaningful log2 here. Validated in
// tests/cpp/test_simd_exp.cpp.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>
#include <cstdint>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>

namespace shannon::kernels::simd {

namespace detail {
inline constexpr double kLn2Recip  = 1.4426950408889634073599;  // log2(e) = 1/ln2
inline constexpr double kSqrt2     = 1.4142135623730951;        // √2, reduction pivot
inline constexpr std::int64_t kMantMask = 0x000FFFFFFFFFFFFFLL;
inline constexpr std::int64_t kOneExp    = 0x3FF0000000000000LL;  // exponent of 1.0
inline constexpr std::int64_t kExpMagic  = 0x4330000000000000LL;  // 2^52 int->double magic
inline constexpr double kExpBias   = 4503599627370496.0 + 1023.0;  // 2^52 + 1023
// atanh series coefficients: log(m) = 2s·Σ s^(2k)/(2k+1), poly in u=s².
inline constexpr double kL7 = 1.0 / 15.0;
inline constexpr double kL6 = 1.0 / 13.0;
inline constexpr double kL5 = 1.0 / 11.0;
inline constexpr double kL4 = 1.0 / 9.0;
inline constexpr double kL3 = 1.0 / 7.0;
inline constexpr double kL2 = 1.0 / 5.0;
inline constexpr double kL1 = 1.0 / 3.0;
inline constexpr double kL0 = 1.0;
}  // namespace detail

// ─── AVX2 (__m256d) ───────────────────────────────────────────────────────────
#if defined(__AVX2__)

[[nodiscard]] static inline __m256d shannon_log2_avx2(__m256d x) noexcept {
    using namespace detail;
    __m256i xi = _mm256_castpd_si256(x);

    // Mantissa m ∈ [1,2): clear exponent, force exponent of 1.0.
    __m256d m = _mm256_castsi256_pd(_mm256_or_si256(
        _mm256_and_si256(xi, _mm256_set1_epi64x(kMantMask)),
        _mm256_set1_epi64x(kOneExp)));

    // Unbiased exponent e as double via the int->double magic trick.
    __m256i biased = _mm256_and_si256(_mm256_srli_epi64(xi, 52),
                                      _mm256_set1_epi64x(0x7FF));
    __m256d e = _mm256_sub_pd(
        _mm256_castsi256_pd(_mm256_or_si256(biased, _mm256_set1_epi64x(kExpMagic))),
        _mm256_set1_pd(kExpBias));

    // Reduce m into [√½, √2): if m > √2, halve m and bump e.
    __m256d gt = _mm256_cmp_pd(m, _mm256_set1_pd(kSqrt2), _CMP_GT_OQ);
    m = _mm256_blendv_pd(m, _mm256_mul_pd(m, _mm256_set1_pd(0.5)), gt);
    e = _mm256_add_pd(e, _mm256_and_pd(gt, _mm256_set1_pd(1.0)));

    // s = (m-1)/(m+1), atanh series in u = s².
    __m256d one = _mm256_set1_pd(1.0);
    __m256d s = _mm256_div_pd(_mm256_sub_pd(m, one), _mm256_add_pd(m, one));
    __m256d u = _mm256_mul_pd(s, s);

    __m256d p = _mm256_set1_pd(kL7);
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL6));
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL5));
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL4));
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL3));
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL2));
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL1));
    p = _mm256_fmadd_pd(p, u, _mm256_set1_pd(kL0));

    // log2(m) = 2·log2(e)·s·p ; log2(x) = e + log2(m).
    __m256d log2m = _mm256_mul_pd(_mm256_mul_pd(s, p),
                                  _mm256_set1_pd(2.0 * kLn2Recip));
    return _mm256_add_pd(e, log2m);
}

#endif  // __AVX2__

// ─── AVX-512 (__m512d) ─────────────────────────────────────────────────────────
#if defined(__AVX512F__)

[[nodiscard]] static inline __m512d shannon_log2_avx512(__m512d x) noexcept {
    using namespace detail;
    __m512i xi = _mm512_castpd_si512(x);

    __m512d m = _mm512_castsi512_pd(_mm512_or_si512(
        _mm512_and_si512(xi, _mm512_set1_epi64(kMantMask)),
        _mm512_set1_epi64(kOneExp)));

    __m512i biased = _mm512_and_si512(_mm512_srli_epi64(xi, 52),
                                      _mm512_set1_epi64(0x7FF));
    __m512d e = _mm512_sub_pd(
        _mm512_castsi512_pd(_mm512_or_si512(biased, _mm512_set1_epi64(kExpMagic))),
        _mm512_set1_pd(kExpBias));

    __mmask8 gt = _mm512_cmp_pd_mask(m, _mm512_set1_pd(kSqrt2), _CMP_GT_OQ);
    m = _mm512_mask_mul_pd(m, gt, m, _mm512_set1_pd(0.5));
    e = _mm512_mask_add_pd(e, gt, e, _mm512_set1_pd(1.0));

    __m512d one = _mm512_set1_pd(1.0);
    __m512d s = _mm512_div_pd(_mm512_sub_pd(m, one), _mm512_add_pd(m, one));
    __m512d u = _mm512_mul_pd(s, s);

    __m512d p = _mm512_set1_pd(kL7);
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL6));
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL5));
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL4));
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL3));
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL2));
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL1));
    p = _mm512_fmadd_pd(p, u, _mm512_set1_pd(kL0));

    __m512d log2m = _mm512_mul_pd(_mm512_mul_pd(s, p),
                                  _mm512_set1_pd(2.0 * kLn2Recip));
    return _mm512_add_pd(e, log2m);
}

#endif  // __AVX512F__

}  // namespace shannon::kernels::simd

#endif  // x86_64
