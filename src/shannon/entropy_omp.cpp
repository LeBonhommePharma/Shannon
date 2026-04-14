// entropy_omp.cpp — OpenMP-accelerated entropy kernels for Shannon 2.0
//
// Compile with OpenMP flags only. No ISA-specific intrinsics.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>

namespace shannon::kernels {

#if defined(SHANNON_USE_OPENMP)

double configurational_entropy_omp(const double* w, std::size_t n) noexcept {
    if (n <= 1) return 0.0;

    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    double Z = 0.0;
    double ws = 0.0;

    #pragma omp parallel for simd reduction(+:Z,ws) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

double entropy_from_probs_omp(const double* p, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;
    double h = 0.0;
    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

double entropy_from_logprobs_omp(const double* lp, std::size_t n) noexcept {
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
