// test_simd_exp.cpp — accuracy tests for the vectorized double-precision exp
//
// Validates shannon::kernels::simd::shannon_exp_{avx2,avx512} against the
// libm std::exp over the domain that matters for log-sum-exp entropy (inputs
// <= 0 after the max-shift), the exact exp(0)==1 requirement, and clean
// flush-to-zero below the double underflow threshold.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include <gtest/gtest.h>

#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"
#include "shannon/simd_generic.hpp"

#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#if defined(__GNUC__) || defined(__clang__)
#include <cpuid.h>
#endif

namespace {

// Compile-time ISA flags do not mean the host CPU can execute those ops
// (GitHub ubuntu runners often compile with AVX512 enabled but SIGILL at run).
inline bool cpu_has_avx2() {
#if defined(__GNUC__) || defined(__clang__)
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) return false;
    return (ebx & (1u << 5)) != 0;  // AVX2
#else
    return true;  // assume OK when we cannot probe
#endif
}

inline bool cpu_has_avx512f() {
#if defined(__GNUC__) || defined(__clang__)
    unsigned int eax = 0, ebx = 0, ecx = 0, edx = 0;
    if (!__get_cpuid_count(7, 0, &eax, &ebx, &ecx, &edx)) return false;
    return (ebx & (1u << 16)) != 0;  // AVX512F
#else
    return true;
#endif
}

// Evaluate the vector exp for a single scalar input by broadcasting.
#if defined(__AVX512F__)
double eval_avx512(double x) {
    alignas(64) double out[8];
    _mm512_store_pd(out, shannon::kernels::simd::shannon_exp_avx512(_mm512_set1_pd(x)));
    return out[0];
}
#endif
#if defined(__AVX2__)
double eval_avx2(double x) {
    alignas(32) double out[4];
    _mm256_store_pd(out, shannon::kernels::simd::shannon_exp_avx2(_mm256_set1_pd(x)));
    return out[0];
}
#endif

// log2 broadcast evaluators.
#if defined(__AVX512F__)
double eval_log2_avx512(double x) {
    alignas(64) double out[8];
    _mm512_store_pd(out, shannon::kernels::simd::shannon_log2_avx512(_mm512_set1_pd(x)));
    return out[0];
}
#endif
#if defined(__AVX2__)
double eval_log2_avx2(double x) {
    alignas(32) double out[4];
    _mm256_store_pd(out, shannon::kernels::simd::shannon_log2_avx2(_mm256_set1_pd(x)));
    return out[0];
}
#endif

// Max relative error of a vectorized log2 vs std::log2 over p ∈ (1e-300, 1],
// including denormal-adjacent inputs and points very close to 1.
template <typename Fn>
double max_rel_error_log2(Fn f) {
    double worst = 0.0;
    auto probe = [&](double p) {
        const double got = f(p);
        const double ref = std::log2(p);
        const double denom = std::abs(ref) > 1e-300 ? std::abs(ref) : 1.0;
        const double rel = std::abs(got - ref) / denom;
        if (rel > worst) worst = rel;
    };
    // Geometric sweep across the full masked domain.
    for (double p = 1e-300; p <= 1.0; p *= 1.09) probe(p);
    // Dense sweep near 1 where log2 -> 0 (relative error is most delicate).
    for (double p = 0.5; p <= 1.0; p += 1e-4) probe(p);
    // Exact-ish anchors.
    for (double p : {1.0, 0.5, 0.25, 0.125, 1.0 / 3.0, 0.9999999, 1e-9, 1e-100, 1e-300}) {
        probe(p);
    }
    return worst;
}

// Sweep the normal-result domain [-708, 0] and report the max relative error.
template <typename Fn>
double max_rel_error(Fn f) {
    double worst = 0.0;
    for (double x = -708.0; x <= 0.0; x += 0.013) {
        const double got = f(x);
        const double ref = std::exp(x);
        const double rel = std::abs(got - ref) / ref;
        if (rel > worst) worst = rel;
    }
    // A few exact anchor points.
    for (double x : {0.0, -0.5, -1.0, -1.0 / 3.0, -50.0, -100.0, -700.0}) {
        const double rel = std::abs(f(x) - std::exp(x)) / std::exp(x);
        if (rel > worst) worst = rel;
    }
    return worst;
}

}  // namespace

#if defined(__AVX512F__)
TEST(SimdExpAvx512, MaxRelativeErrorUnder1e12) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    EXPECT_LT(max_rel_error(eval_avx512), 1e-12);
}
TEST(SimdExpAvx512, ExactAtZero) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    EXPECT_EQ(eval_avx512(0.0), 1.0);
}
TEST(SimdExpAvx512, FlushToZeroBelowUnderflow) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    EXPECT_EQ(eval_avx512(-745.5), 0.0);   // below smallest subnormal
    EXPECT_EQ(eval_avx512(-800.0), 0.0);
    EXPECT_EQ(eval_avx512(-1000.0), 0.0);
}
TEST(SimdExpAvx512, DeepNegativeSaturatesToZero) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    // Regression: before the kExpFlush saturation, the 2^n exponent-bit trick
    // wrapped for x < ~-1418 and returned Inf / huge garbage (observed at
    // x=-1420 and x=-2000 on AVX2). A masked-vocab logit spread can produce
    // such shifts legitimately.
    for (double x : {-709.0, -1418.0, -1420.0, -2000.0, -1e6, -1e300}) {
        EXPECT_EQ(eval_avx512(x), 0.0) << "x=" << x;
        EXPECT_FALSE(std::signbit(eval_avx512(x))) << "must be +0, x=" << x;
    }
}
TEST(SimdExpAvx512, NoNaNAnywhereOnNegativeDomain) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    for (double x = 0.0; x >= -1000.0; x -= 0.7) {
        const double v = eval_avx512(x);
        EXPECT_FALSE(std::isnan(v)) << "NaN at x=" << x;
        EXPECT_GE(v, 0.0);
    }
}
TEST(SimdExpAvx512, SubnormalRangeFiniteAndSmall) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    // exp(-745..-709) is subnormal; must stay finite, non-negative, tiny.
    for (double x = -709.0; x >= -745.0; x -= 0.5) {
        const double v = eval_avx512(x);
        EXPECT_TRUE(std::isfinite(v));
        EXPECT_GE(v, 0.0);
        EXPECT_LT(v, 1e-307);
    }
}
#endif

#if defined(__AVX2__)
TEST(SimdExpAvx2, MaxRelativeErrorUnder1e12) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    EXPECT_LT(max_rel_error(eval_avx2), 1e-12);
}
TEST(SimdExpAvx2, ExactAtZero) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    EXPECT_EQ(eval_avx2(0.0), 1.0);
}
TEST(SimdExpAvx2, FlushToZeroBelowUnderflow) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    EXPECT_EQ(eval_avx2(-745.5), 0.0);
    EXPECT_EQ(eval_avx2(-800.0), 0.0);
    EXPECT_EQ(eval_avx2(-1000.0), 0.0);
}
TEST(SimdExpAvx2, DeepNegativeSaturatesToZero) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    for (double x : {-709.0, -1418.0, -1420.0, -2000.0, -1e6, -1e300}) {
        EXPECT_EQ(eval_avx2(x), 0.0) << "x=" << x;
        EXPECT_FALSE(std::signbit(eval_avx2(x))) << "must be +0, x=" << x;
    }
}
TEST(SimdExpAvx2, NoNaNAnywhereOnNegativeDomain) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    for (double x = 0.0; x >= -1000.0; x -= 0.7) {
        const double v = eval_avx2(x);
        EXPECT_FALSE(std::isnan(v)) << "NaN at x=" << x;
        EXPECT_GE(v, 0.0);
    }
}
#endif

// ─── log2 accuracy ─────────────────────────────────────────────────────────────
#if defined(__AVX512F__)
TEST(SimdLog2Avx512, MaxRelativeErrorUnder1e12) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    EXPECT_LT(max_rel_error_log2(eval_log2_avx512), 1e-12);
}
TEST(SimdLog2Avx512, ExactAtOne) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    EXPECT_EQ(eval_log2_avx512(1.0), 0.0);  // log2(1) == 0 exactly
}
TEST(SimdLog2Avx512, ExactAtPowersOfTwo) {
    if (!cpu_has_avx512f()) GTEST_SKIP() << "host CPU lacks AVX512F";
    EXPECT_NEAR(eval_log2_avx512(0.5), -1.0, 1e-14);
    EXPECT_NEAR(eval_log2_avx512(0.25), -2.0, 1e-14);
    EXPECT_NEAR(eval_log2_avx512(1e-300), std::log2(1e-300), 1e-12 * 997.0);
}
#endif

#if defined(__AVX2__)
TEST(SimdLog2Avx2, MaxRelativeErrorUnder1e12) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    EXPECT_LT(max_rel_error_log2(eval_log2_avx2), 1e-12);
}
TEST(SimdLog2Avx2, ExactAtOne) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    EXPECT_EQ(eval_log2_avx2(1.0), 0.0);
}
TEST(SimdLog2Avx2, ExactAtPowersOfTwo) {
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    if (!cpu_has_avx2()) GTEST_SKIP() << "host CPU lacks AVX2";
    EXPECT_NEAR(eval_log2_avx2(0.5), -1.0, 1e-14);
    EXPECT_NEAR(eval_log2_avx2(0.25), -2.0, 1e-14);
    EXPECT_NEAR(eval_log2_avx2(1e-300), std::log2(1e-300), 1e-12 * 997.0);
}
#endif

#if defined(SHANNON_SIMD_GENERIC_EXPERIMENTAL)
namespace {
double eval_generic_exp(double x) {
    using V = shannon::kernels::simd::abi::native<double>;
    return shannon::kernels::simd::shannon_exp_generic(V(x))[0];
}
double eval_generic_log2(double x) {
    using V = shannon::kernels::simd::abi::native<double>;
    return shannon::kernels::simd::shannon_log2_generic(V(x))[0];
}

// This TU is compiled with the widest -m flags (AVX2 and often AVX-512), so
// native_simd<double> follows that width. size()==8 needs AVX-512 at runtime;
// hosted runners advertise AVX-512 in CPUID then SIGILL. Skip here and keep
// the suites in the CI -E filter (same policy as SimdLog2Avx2.MaxRelativeError).
bool generic_native_runnable() {
    using V = shannon::kernels::simd::abi::native<double>;
    if (V::size() >= 8 && !cpu_has_avx512f()) return false;
    if (V::size() >= 4 && !cpu_has_avx2()) return false;
    return true;
}
}  // namespace

TEST(SimdExpGeneric, MaxRelativeErrorUnder1e13) {
    if (!generic_native_runnable()) {
        GTEST_SKIP() << "host cannot execute native_simd width";
    }
    EXPECT_LT(max_rel_error(eval_generic_exp), 1e-13);
}
TEST(SimdExpGeneric, ExactAtZero) {
    if (!generic_native_runnable()) {
        GTEST_SKIP() << "host cannot execute native_simd width";
    }
    EXPECT_EQ(eval_generic_exp(0.0), 1.0);
}
TEST(SimdExpGeneric, DeepNegativeSaturatesToZero) {
    if (!generic_native_runnable()) {
        GTEST_SKIP() << "host cannot execute native_simd width";
    }
    for (double x : {-709.0, -1418.0, -1420.0, -2000.0, -1e6, -1e300}) {
        EXPECT_EQ(eval_generic_exp(x), 0.0) << "x=" << x;
        EXPECT_FALSE(std::signbit(eval_generic_exp(x))) << "must be +0, x=" << x;
    }
}
TEST(SimdLog2Generic, MaxRelativeErrorUnder1e12) {
    if (!generic_native_runnable()) {
        GTEST_SKIP() << "host cannot execute native_simd width";
    }
    EXPECT_LT(max_rel_error_log2(eval_generic_log2), 1e-12);
}
TEST(SimdLog2Generic, ExactAtOne) {
    if (!generic_native_runnable()) {
        GTEST_SKIP() << "host cannot execute native_simd width";
    }
    EXPECT_EQ(eval_generic_log2(1.0), 0.0);
}
#endif

#else  // non-x86: nothing to test here
TEST(SimdExp, SkippedOnNonX86) { GTEST_SKIP() << "SIMD exp test is x86-only"; }
#endif
