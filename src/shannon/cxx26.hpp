// cxx26.hpp — C++26 dialect / library capability report and opportunistic helpers
//
// Honest feature-test surface. Do not pretend contracts, reflection, pack
// indexing, `#embed`, `function_ref`, or P1928 `<simd>` exist on a toolchain
// that does not define the corresponding macros. Callers must branch on these
// constexprs (or the macros themselves), not on SHANNON_CXX_STANDARD.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>
#include <tuple>
#include <type_traits>
#include <version>

#if defined(__has_include)
#  if __has_include(<simd>)
#    define SHANNON_CXX26_HAS_INCLUDE_STD_SIMD 1
#  endif
#  if __has_include(<experimental/simd>)
#    define SHANNON_CXX26_HAS_INCLUDE_EXPERIMENTAL_SIMD 1
#  endif
#  if __has_include(<mdspan>)
#    define SHANNON_CXX26_HAS_INCLUDE_MDSPAN 1
#  endif
#  if __has_include(<meta>)
#    define SHANNON_CXX26_HAS_INCLUDE_META 1
#  endif
#endif

#if defined(__has_cpp_attribute)
#  if __has_cpp_attribute(assume)
#    define SHANNON_ASSUME(expr) [[assume(expr)]]
#  endif
#endif
#ifndef SHANNON_ASSUME
#  define SHANNON_ASSUME(expr) ((void)0)
#endif

// P2900 contract_assert. Compilers without contracts see a no-op; do not use
// this to replace fail-closed runtime guards (n<=1 → H=0 still returns 0).
#if defined(__cpp_contracts)
#  define SHANNON_CONTRACT_ASSERT(...) contract_assert(__VA_ARGS__)
#else
#  define SHANNON_CONTRACT_ASSERT(...) ((void)0)
#endif

namespace shannon::cxx26 {

// Language dialect the TU was compiled as (not the CMake cache value).
inline constexpr bool dialect_26 = (__cplusplus >= 202400L);
inline constexpr bool dialect_23 = (__cplusplus >= 202302L);

inline constexpr bool has_std_simd =
#if defined(__cpp_lib_simd)
    true;
#else
    false;
#endif

inline constexpr bool has_experimental_simd_header =
#if defined(SHANNON_CXX26_HAS_INCLUDE_EXPERIMENTAL_SIMD)
    true;
#else
    false;
#endif

inline constexpr bool has_contracts =
#if defined(__cpp_contracts)
    true;
#else
    false;
#endif

inline constexpr bool has_reflection =
#if defined(__cpp_impl_reflection) || defined(__cpp_reflection)
    true;
#else
    false;
#endif

inline constexpr bool has_reflection_header =
#if defined(SHANNON_CXX26_HAS_INCLUDE_META)
    true;
#else
    false;
#endif

inline constexpr bool has_pack_indexing =
#if defined(__cpp_pack_indexing)
    true;
#else
    false;
#endif

inline constexpr bool has_embed =
#if defined(__cpp_embed)
    true;
#else
    false;
#endif

inline constexpr bool has_embed_operator =
#if defined(__has_embed)
    true;
#else
    false;
#endif

inline constexpr bool has_function_ref =
#if defined(__cpp_lib_function_ref)
    true;
#else
    false;
#endif

// Require the feature-test macro, not a lone `__has_include`. libc++ has
// shipped headers that exist but are not the IS API (see experimental simd).
inline constexpr bool has_mdspan =
#if defined(__cpp_lib_mdspan)
    true;
#else
    false;
#endif

inline constexpr bool has_mdspan_header =
#if defined(SHANNON_CXX26_HAS_INCLUDE_MDSPAN)
    true;
#else
    false;
#endif

inline constexpr bool has_placeholder_variables =
#if defined(__cpp_placeholder_variables)
    true;
#else
    false;
#endif

inline constexpr bool has_assume_attr =
#if defined(__has_cpp_attribute) && __has_cpp_attribute(assume)
    true;
#else
    false;
#endif

// Pack indexing hatch for kernel type lists. Ts...[I] when the language has
// it; std::tuple_element otherwise (C++20 hatch).
template <std::size_t I, class... Ts>
struct nth_type {
#if defined(__cpp_pack_indexing)
    using type = Ts...[I];
#else
    using type = std::tuple_element_t<I, std::tuple<Ts...>>;
#endif
};

template <std::size_t I, class... Ts>
using nth_type_t = typename nth_type<I, Ts...>::type;

template <std::size_t I, auto... Vs>
inline constexpr auto nth_value =
#if defined(__cpp_pack_indexing)
    Vs...[I];
#else
    std::get<I>(std::tuple{Vs...});
#endif

}  // namespace shannon::cxx26
