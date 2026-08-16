// simd_generic.hpp — Horner exp / atanh log2 on portable SIMD
//
// One Horner / IEEE 2^n / atanh log2. The ABI layer is:
//   1. P1928 `std::simd::vec<T>` when `__cpp_lib_simd` (GCC 16+ `<simd>`).
//      Native width is the default `vec<T>` (no `simd_abi` namespace in the IS).
//   2. Else Parallelism TS `std::experimental::native_simd<T>` (libstdc++ today).
//
// Do **not** call scalar std::exp / std::log2 per lane (that is the ~92 M
// elem/s regression). C++26 [simd.math] still lacks Shannon's exp/log2 (and
// on GCC 16 even fma/floor/nearbyint), so those stay in this header.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>
#include <version>

// Prefer the IS type. Do not include a libc++ <simd> look-alike without the
// feature-test macro (same class of bug as Apple <experimental/simd>).
#if defined(__cpp_lib_simd) && defined(__has_include) && __has_include(<simd>)
#include <simd>
#include <span>
#define SHANNON_SIMD_GENERIC_P1928 1
#define SHANNON_SIMD_GENERIC 1
#elif defined(__GLIBCXX__) && defined(__has_include) && __has_include(<experimental/simd>)
#include <experimental/simd>
#if defined(__cpp_lib_experimental_parallel_simd)
#define SHANNON_SIMD_GENERIC_EXPERIMENTAL 1
#define SHANNON_SIMD_GENERIC 1
#endif
#endif

#if defined(SHANNON_SIMD_GENERIC)

namespace shannon::kernels::simd {

namespace abi {

template <class V>
[[nodiscard]] constexpr std::size_t lane_count() noexcept {
    if constexpr (requires { static_cast<std::size_t>(V::size()); }) {
        return static_cast<std::size_t>(V::size());
    } else {
        return static_cast<std::size_t>(V::size);
    }
}

#if defined(SHANNON_SIMD_GENERIC_P1928)

template <class T>
using native = std::simd::vec<T>;
template <class T, class V>
using rebind = std::simd::rebind_t<T, V>;

template <class V>
[[nodiscard]] inline V load(const typename V::value_type* p) noexcept {
    constexpr std::size_t n = lane_count<V>();
    return std::simd::unchecked_load<V>(
        std::span<const typename V::value_type, n>(p, n));
}

template <class V>
inline void store(const V& v, typename V::value_type* p) noexcept {
    constexpr std::size_t n = lane_count<V>();
    std::simd::unchecked_store(v, std::span<typename V::value_type, n>(p, n));
}

template <class V>
[[nodiscard]] inline V fma(const V& a, const V& b, const V& c) noexcept {
    // GCC 16 [simd.math] does not ship vector fma. The entropy TU is built
    // with -mfma on x86 so a*b+c should contract; never scalar std::fma/lane.
    return a * b + c;
}

template <class Mask, class V>
class where_expr {
    Mask mask_;
    V& dest_;
public:
    where_expr(Mask m, V& d) noexcept : mask_(m), dest_(d) {}
    where_expr& operator=(const V& v) noexcept {
        dest_ = std::simd::select(mask_, v, dest_);
        return *this;
    }
};

template <class Mask, class V>
[[nodiscard]] inline where_expr<Mask, V> where(Mask m, V& dest) noexcept {
    return where_expr<Mask, V>(m, dest);
}

template <class V>
[[nodiscard]] inline auto reduce(const V& v) noexcept {
    return std::simd::reduce(v);
}

template <class V>
[[nodiscard]] inline auto isfinite(const V& x) noexcept {
    if constexpr (requires { std::simd::isnan(x); } && requires { std::simd::isinf(x); }) {
        return !std::simd::isnan(x) && !std::simd::isinf(x);
    } else {
        return (x * V(0.0)) == V(0.0);
    }
}

template <class V>
[[nodiscard]] inline V nearbyint(V x) noexcept {
    if constexpr (requires { std::nearbyint(x); } &&
                  !std::is_same_v<decltype(std::nearbyint(x)), double>) {
        return std::nearbyint(x);
    } else {
        // |x| in the exp-reduction domain is << 2^52. Magic round, no libm.
        const V two52 = V(4503599627370496.0);
        V magic = two52;
        where(x < V(0.0), magic) = V(-4503599627370496.0);
        return (x + magic) - magic;
    }
}

template <class V>
[[nodiscard]] inline V floor(V x) noexcept {
    if constexpr (requires { std::floor(x); } &&
                  !std::is_same_v<decltype(std::floor(x)), double>) {
        return std::floor(x);
    } else {
        V n = nearbyint(x);
        where(n > x, n) = n - V(1.0);
        return n;
    }
}

#else  // SHANNON_SIMD_GENERIC_EXPERIMENTAL

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

template <class V>
[[nodiscard]] inline V load(const typename V::value_type* p) noexcept {
    return V(p, element_aligned);
}

template <class V>
inline void store(const V& v, typename V::value_type* p) noexcept {
    v.copy_to(p, element_aligned);
}

#endif

}  // namespace abi

namespace generic_detail {

template <class To, class From>
[[nodiscard]] inline To bitcast_simd(const From& src) noexcept {
    static_assert(abi::lane_count<To>() == abi::lane_count<From>());
    alignas(From) typename From::value_type in[abi::lane_count<From>()];
    abi::store(src, in);
    alignas(To) typename To::value_type out[abi::lane_count<To>()];
    static_assert(sizeof(in) == sizeof(out));
    std::memcpy(out, in, sizeof(out));
    return abi::load<To>(out);
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

#endif  // SHANNON_SIMD_GENERIC
