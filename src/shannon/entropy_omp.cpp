// entropy_omp.cpp — OpenMP-accelerated entropy kernels for Shannon 2.0
//
// Compile with OpenMP flags only. No ISA-specific intrinsics.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/entropy_algorithm.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <limits>

namespace shannon::kernels {

#if defined(SHANNON_USE_OPENMP)

double configurational_entropy_omp(std::span<const double> weights) noexcept {
    const double* w = weights.data();
    const std::size_t n = weights.size();
    if (n <= 1) return 0.0;

    // Same scan as entropy_algorithm.hpp (OpenMP is a reduction specialization).
    const auto support = detail::scan_logit_support(weights);
    if (support.any_pos_inf || !support.any_finite) return 0.0;
    const double max_w = support.max_finite;

    double Z = 0.0;
    double ws = 0.0;

    #pragma omp parallel for simd reduction(+:Z,ws) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double shifted = w[i] - max_w;
        if (std::isfinite(shifted)) {
            const double ev = std::exp(shifted);
            Z += ev;
            ws += shifted * ev;
        }
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_omp(std::span<const double> probs) noexcept {
    const double* p = probs.data();
    const std::size_t n = probs.size();
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;
    double h = 0.0;
    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_omp(std::span<const double> logprobs) noexcept {
    const double* lp = logprobs.data();
    const std::size_t n = logprobs.size();
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;
    double h = 0.0;
    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::fmax(0.0, h);
}

#endif  // SHANNON_USE_OPENMP

}  // namespace shannon::kernels
