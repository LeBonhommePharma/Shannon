// cxx26.hpp — C++26 dialect / library capability report and opportunistic helpers
//
// Honest feature-test surface for ENH-037. Do not pretend contracts, reflection,
// pack indexing, `#embed`, `function_ref`, or P1928 `<simd>` exist on a
// toolchain that does not define the corresponding macros. Callers must branch
// on these constexprs (or the macros themselves), not on SHANNON_CXX_STANDARD.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

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
#endif

#if defined(__has_cpp_attribute)
#  if __has_cpp_attribute(assume)
#    define SHANNON_ASSUME(expr) [[assume(expr)]]
#  endif
#endif
#ifndef SHANNON_ASSUME
#  define SHANNON_ASSUME(expr) ((void)0)
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

inline constexpr bool has_function_ref =
#if defined(__cpp_lib_function_ref)
    true;
#else
    false;
#endif

inline constexpr bool has_mdspan =
#if defined(__cpp_lib_mdspan) || defined(SHANNON_CXX26_HAS_INCLUDE_MDSPAN)
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

}  // namespace shannon::cxx26
