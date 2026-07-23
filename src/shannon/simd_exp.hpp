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
// Accuracy: max relative error vs std::exp < 1e-13 over [-708, 0], the domain
// that matters (inputs <= 0 after the log-sum-exp max-shift; below -708 the
// true value is subnormal/zero and contributes nothing to Z >= 1).
// exp(0) == 1.0 exactly. Inputs below kExpFlush = -708 return exactly +0.0 —
// saturated, never Inf/NaN/garbage even for arbitrarily negative x (see the
// kExpFlush note). Validated in tests/cpp/test_simd_exp.cpp (x86) and
// tests/cpp/test_neon_kernels.cpp under qemu-aarch64 (NEON).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#endif
#if defined(__ARM_NEON) || defined(__aarch64__)
#include <arm_neon.h>
#endif

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
// Flush threshold: below this, exp(x) < ~3.3e-308 (the smallest normal double
// is ~2.2e-308) and the contribution to any log-sum-exp with a 0-shifted max
// (Z >= 1) is far below one ulp — physically zero. Saturating here also keeps
// the 2^n exponent-bit trick inside its valid range: without it, n1+1023
// underflows the exponent field for x < ~-1418 and the kernel returns Inf or
// huge garbage instead of 0 (observed at x=-1420 and x=-2000 on AVX2 — a
// masked-vocab logit spread can legitimately produce such inputs).
inline constexpr double kExpFlush = -708.0;
}  // namespace detail

// ─── NEON (float64x2_t) ───────────────────────────────────────────────────────
// Same algorithm and constants as the x86 paths below; validated against
// std::exp under qemu-aarch64 (scripts/test_neon_qemu.sh) — same harness a
// native Apple Silicon build runs via ctest.
#if defined(__ARM_NEON) || defined(__aarch64__)

[[nodiscard]] static inline float64x2_t shannon_pow2_half_neon(float64x2_t k) noexcept {
    // (k + kMagic) holds the integer k+1023 in its low mantissa bits;
    // shifting left by 52 moves it into the IEEE-754 exponent field.
    float64x2_t a = vaddq_f64(k, vdupq_n_f64(detail::kMagic));
    int64x2_t   b = vshlq_n_s64(vreinterpretq_s64_f64(a), 52);
    return vreinterpretq_f64_s64(b);
}

[[nodiscard]] static inline float64x2_t shannon_exp_neon(float64x2_t x) noexcept {
    using namespace detail;
    // n = round-to-nearest(x / ln2)   (vrndnq: round to nearest, ties to even)
    float64x2_t n = vrndnq_f64(vmulq_f64(x, vdupq_n_f64(kLog2E)));
    // r = x - n*ln2  (two-part subtraction; vfmsq(a,b,c) = a - b*c)
    float64x2_t r = vfmsq_f64(x, n, vdupq_n_f64(kC1));
    r = vfmsq_f64(r, n, vdupq_n_f64(kC2));

    // exp(r) via degree-13 Horner Taylor (vfmaq(a,b,c) = a + b*c)
    float64x2_t p = vdupq_n_f64(kT13);
    p = vfmaq_f64(vdupq_n_f64(kT12), p, r);
    p = vfmaq_f64(vdupq_n_f64(kT11), p, r);
    p = vfmaq_f64(vdupq_n_f64(kT10), p, r);
    p = vfmaq_f64(vdupq_n_f64(kT9),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT8),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT7),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT6),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT5),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT4),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT3),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT2),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT1),  p, r);
    p = vfmaq_f64(vdupq_n_f64(kT0),  p, r);

    // 2^n via two half-scales
    float64x2_t n1 = vrndmq_f64(vmulq_f64(n, vdupq_n_f64(0.5)));  // floor
    float64x2_t n2 = vsubq_f64(n, n1);
    float64x2_t scale = vmulq_f64(shannon_pow2_half_neon(n1),
                                  shannon_pow2_half_neon(n2));
    float64x2_t res = vmulq_f64(p, scale);

    // Saturate: lanes with x < kExpFlush return exactly +0.0 (see detail note).
    uint64x2_t keep = vcgeq_f64(x, vdupq_n_f64(kExpFlush));
    return vreinterpretq_f64_u64(vandq_u64(keep, vreinterpretq_u64_f64(res)));
}

#endif  // NEON

// ─── AVX2 (__m256d) ───────────────────────────────────────────────────────────
#if (defined(__x86_64__) || defined(_M_X64)) && defined(__AVX2__)

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

    // 2^n via two half-scales
    __m256d n1 = _mm256_floor_pd(_mm256_mul_pd(n, _mm256_set1_pd(0.5)));
    __m256d n2 = _mm256_sub_pd(n, n1);
    __m256d scale = _mm256_mul_pd(shannon_pow2_half_avx2(n1),
                                  shannon_pow2_half_avx2(n2));
    __m256d res = _mm256_mul_pd(p, scale);

    // Saturate: lanes with x < kExpFlush return exactly +0.0 (see detail note).
    return _mm256_and_pd(res,
        _mm256_cmp_pd(x, _mm256_set1_pd(kExpFlush), _CMP_GE_OQ));
}

#endif  // __AVX2__

// ─── AVX-512 (__m512d) ─────────────────────────────────────────────────────────
#if (defined(__x86_64__) || defined(_M_X64)) && defined(__AVX512F__)

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
    __m512d res = _mm512_mul_pd(p, scale);

    // Saturate: lanes with x < kExpFlush return exactly +0.0 (see detail note).
    __mmask8 keep = _mm512_cmp_pd_mask(x, _mm512_set1_pd(kExpFlush), _CMP_GE_OQ);
    return _mm512_maskz_mov_pd(keep, res);
}

#endif  // __AVX512F__

}  // namespace shannon::kernels::simd
