// entropy.hpp — Entropy kernel declarations for all backends
//
// Pure C++20 entropy collapse detection — Le Bonhomme Pharma / NRGlab
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>

namespace shannon::kernels {

// ─── Configurational entropy (log-sum-exp from logits) ────────────────────────

[[nodiscard]] double configurational_entropy_scalar(const double* w, std::size_t n) noexcept;

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double configurational_entropy_omp(const double* w, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_SSE42) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double configurational_entropy_sse42(const double* w, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double configurational_entropy_avx2(const double* w, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double configurational_entropy_avx512(const double* w, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
[[nodiscard]] double configurational_entropy_neon(const double* w, std::size_t n) noexcept;
#endif

// ─── Shannon entropy from probabilities ───────────────────────────────────────

[[nodiscard]] double entropy_from_probs_scalar(const double* p, std::size_t n) noexcept;

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double entropy_from_probs_omp(const double* p, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_probs_avx2(const double* p, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_probs_avx512(const double* p, std::size_t n) noexcept;
#endif

// ─── Shannon entropy from log-probabilities ───────────────────────────────────

[[nodiscard]] double entropy_from_logprobs_scalar(const double* lp, std::size_t n) noexcept;

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double entropy_from_logprobs_omp(const double* lp, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_logprobs_avx2(const double* lp, std::size_t n) noexcept;
#endif

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_logprobs_avx512(const double* lp, std::size_t n) noexcept;
#endif

}  // namespace shannon::kernels
