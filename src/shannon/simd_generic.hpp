// simd_generic.hpp — Horner exp / atanh log2 on portable SIMD
//
// Re-expresses the same constants and algorithm as simd_exp.hpp / simd_log2.hpp
// on `std::experimental::native_simd<double>` (Parallelism TS; libstdc++ today).
// P1928 `std::simd` (`<simd>`, `__cpp_lib_simd`) is **not** in GCC 14 — when
// that header lands, point `abi::native` at `std::simd<double>` without
// changing the Horner. Do **not** call scalar std::exp / std::log2 per lane
// (that is the ~92 M elem/s regression). C++26 [simd.math] is also missing.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>

// libstdc++ Parallelism TS (`native_simd`, `element_aligned`, `rebind_simd_t`).
// Do not include <experimental/simd> on libc++ / Apple: `__has_include` can
// be true for a header that is not that API (macOS CI / Homebrew HEAD).
#if defined(__GLIBCXX__) && defined(__has_include) && __has_include(<experimental/simd>)
#include <experimental/simd>
#if defined(__cpp_lib_experimental_parallel_simd)
#define SHANNON_SIMD_GENERIC_EXPERIMENTAL 1
#endif
#endif

#if defined(SHANNON_SIMD_GENERIC_EXPERIMENTAL)

namespace shannon::kernels::simd {

namespace abi {
namespace stdx = std::experimental;
template <class T>
using native = stdx::native_simd<T>;
template <class T, class V>
using rebind = stdx::rebind_simd_t<T, V>;
using stdx::element_aligned;
using stdx::fma;
using stdx::floor;
using stdx::isfinite;
using stdx::nearbyint;
using stdx::reduce;
using stdx::where;
}  // namespace abi

namespace generic_detail {

template <class To, class From>
[[nodiscard]] inline To bitcast_simd(const From& src) noexcept {
    static_assert(To::size() == From::size());
    alignas(From) typename From::value_type in[From::size()];
    src.copy_to(in, abi::element_aligned);
    alignas(To) typename To::value_type out[To::size()];
    static_assert(sizeof(in) == sizeof(out));
    std::memcpy(out, in, sizeof(out));
    return To(out, abi::element_aligned);
}

template <class V>
[[nodiscard]] inline V pow2_half(V k) noexcept {
    using I = abi::rebind<std::int64_t, V>;
    const V a = k + V(detail::kMagic);
    const I b = bitcast_simd<I>(a) << 52;
    return bitcast_simd<V>(b);
}

}  // namespace generic_detail

// Same Horner / IEEE 2^n construction as shannon_exp_avx2, on a generic SIMD type.
template <class V>
[[nodiscard]] inline V shannon_exp_generic(V x) noexcept {
    using namespace detail;
    const V n = abi::nearbyint(x * V(kLog2E));
    V r = abi::fma(-n, V(kC1), x);
    r = abi::fma(-n, V(kC2), r);

    V p = V(kT13);
    p = abi::fma(p, r, V(kT12));
    p = abi::fma(p, r, V(kT11));
    p = abi::fma(p, r, V(kT10));
    p = abi::fma(p, r, V(kT9));
    p = abi::fma(p, r, V(kT8));
    p = abi::fma(p, r, V(kT7));
    p = abi::fma(p, r, V(kT6));
    p = abi::fma(p, r, V(kT5));
    p = abi::fma(p, r, V(kT4));
    p = abi::fma(p, r, V(kT3));
    p = abi::fma(p, r, V(kT2));
    p = abi::fma(p, r, V(kT1));
    p = abi::fma(p, r, V(kT0));

    const V n1 = abi::floor(n * V(0.5));
    const V n2 = n - n1;
    V res = p * generic_detail::pow2_half(n1) * generic_detail::pow2_half(n2);
    abi::where(x < V(kExpFlush), res) = V(0.0);
    return res;
}

// Same atanh / IEEE split as shannon_log2_avx2, on a generic SIMD type.
template <class V>
[[nodiscard]] inline V shannon_log2_generic(V x) noexcept {
    using namespace detail;
    using I = abi::rebind<std::int64_t, V>;

    const I xi = generic_detail::bitcast_simd<I>(x);
    const I mbits = (xi & I(kMantMask)) | I(kOneExp);
    V m = generic_detail::bitcast_simd<V>(mbits);

    const I biased = (generic_detail::bitcast_simd<I>(x) >> 52) & I(0x7FF);
    V e = generic_detail::bitcast_simd<V>(biased | I(kExpMagic)) - V(kExpBias);

    const auto gt = m > V(kSqrt2);
    abi::where(gt, m) = m * V(0.5);
    abi::where(gt, e) = e + V(1.0);

    const V one = V(1.0);
    const V s = (m - one) / (m + one);
    const V u = s * s;
    V p = V(kL7);
    p = abi::fma(p, u, V(kL6));
    p = abi::fma(p, u, V(kL5));
    p = abi::fma(p, u, V(kL4));
    p = abi::fma(p, u, V(kL3));
    p = abi::fma(p, u, V(kL2));
    p = abi::fma(p, u, V(kL1));
    p = abi::fma(p, u, V(kL0));
    return e + s * p * V(2.0 * kLn2Recip);
}

}  // namespace shannon::kernels::simd

#endif  // SHANNON_SIMD_GENERIC_EXPERIMENTAL
