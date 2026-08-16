// entropy.hpp — Entropy kernel declarations for all backends
//
// Pure C++20 entropy collapse detection — Le Bonhomme Pharma / NRGlab
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>
#include <span>

namespace shannon::kernels {

namespace detail {

// Pointer+size → span without constructing a non-empty span from nullptr
// (which is UB). Empty / null inputs become an empty span; kernels treat
// n <= 1 as H = 0.
[[nodiscard]] inline std::span<const double>
as_span(const double* p, std::size_t n) noexcept {
    if (p == nullptr || n == 0) {
        return {};
    }
    return std::span<const double>{p, n};
}

}  // namespace detail

// ─── Configurational entropy (log-sum-exp from logits) ────────────────────────

[[nodiscard]] double configurational_entropy_scalar(std::span<const double> w) noexcept;
[[nodiscard]] inline double configurational_entropy_scalar(const double* w, std::size_t n) noexcept {
    return configurational_entropy_scalar(detail::as_span(w, n));
}

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double configurational_entropy_omp(std::span<const double> w) noexcept;
[[nodiscard]] inline double configurational_entropy_omp(const double* w, std::size_t n) noexcept {
    return configurational_entropy_omp(detail::as_span(w, n));
}
#endif

#if defined(SHANNON_USE_SSE42) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double configurational_entropy_sse42(std::span<const double> w) noexcept;
[[nodiscard]] inline double configurational_entropy_sse42(const double* w, std::size_t n) noexcept {
    return configurational_entropy_sse42(detail::as_span(w, n));
}
#endif

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double configurational_entropy_avx2(std::span<const double> w) noexcept;
[[nodiscard]] inline double configurational_entropy_avx2(const double* w, std::size_t n) noexcept {
    return configurational_entropy_avx2(detail::as_span(w, n));
}
#endif

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double configurational_entropy_avx512(std::span<const double> w) noexcept;
[[nodiscard]] inline double configurational_entropy_avx512(const double* w, std::size_t n) noexcept {
    return configurational_entropy_avx512(detail::as_span(w, n));
}
#endif

#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
[[nodiscard]] double configurational_entropy_neon(std::span<const double> w) noexcept;
[[nodiscard]] inline double configurational_entropy_neon(const double* w, std::size_t n) noexcept {
    return configurational_entropy_neon(detail::as_span(w, n));
}
[[nodiscard]] double entropy_from_probs_neon(std::span<const double> p) noexcept;
[[nodiscard]] inline double entropy_from_probs_neon(const double* p, std::size_t n) noexcept {
    return entropy_from_probs_neon(detail::as_span(p, n));
}
[[nodiscard]] double entropy_from_logprobs_neon(std::span<const double> lp) noexcept;
[[nodiscard]] inline double entropy_from_logprobs_neon(const double* lp, std::size_t n) noexcept {
    return entropy_from_logprobs_neon(detail::as_span(lp, n));
}
#endif

// ─── Shannon entropy from probabilities ───────────────────────────────────────

[[nodiscard]] double entropy_from_probs_scalar(std::span<const double> p) noexcept;
[[nodiscard]] inline double entropy_from_probs_scalar(const double* p, std::size_t n) noexcept {
    return entropy_from_probs_scalar(detail::as_span(p, n));
}

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double entropy_from_probs_omp(std::span<const double> p) noexcept;
[[nodiscard]] inline double entropy_from_probs_omp(const double* p, std::size_t n) noexcept {
    return entropy_from_probs_omp(detail::as_span(p, n));
}
#endif

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_probs_avx2(std::span<const double> p) noexcept;
[[nodiscard]] inline double entropy_from_probs_avx2(const double* p, std::size_t n) noexcept {
    return entropy_from_probs_avx2(detail::as_span(p, n));
}
#endif

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_probs_avx512(std::span<const double> p) noexcept;
[[nodiscard]] inline double entropy_from_probs_avx512(const double* p, std::size_t n) noexcept {
    return entropy_from_probs_avx512(detail::as_span(p, n));
}
#endif

// ─── Shannon entropy from log-probabilities ───────────────────────────────────

[[nodiscard]] double entropy_from_logprobs_scalar(std::span<const double> lp) noexcept;
[[nodiscard]] inline double entropy_from_logprobs_scalar(const double* lp, std::size_t n) noexcept {
    return entropy_from_logprobs_scalar(detail::as_span(lp, n));
}

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double entropy_from_logprobs_omp(std::span<const double> lp) noexcept;
[[nodiscard]] inline double entropy_from_logprobs_omp(const double* lp, std::size_t n) noexcept {
    return entropy_from_logprobs_omp(detail::as_span(lp, n));
}
#endif

#if defined(SHANNON_USE_AVX2) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_logprobs_avx2(std::span<const double> lp) noexcept;
[[nodiscard]] inline double entropy_from_logprobs_avx2(const double* lp, std::size_t n) noexcept {
    return entropy_from_logprobs_avx2(detail::as_span(lp, n));
}
#endif

#if defined(SHANNON_USE_AVX512) && (defined(__x86_64__) || defined(_M_X64))
[[nodiscard]] double entropy_from_logprobs_avx512(std::span<const double> lp) noexcept;
[[nodiscard]] inline double entropy_from_logprobs_avx512(const double* lp, std::size_t n) noexcept {
    return entropy_from_logprobs_avx512(detail::as_span(lp, n));
}
#endif

}  // namespace shannon::kernels
