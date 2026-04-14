// entropy_scalar.cpp — Scalar (baseline) entropy kernels
//
// Pure C++20 entropy collapse detection — Le Bonhomme Pharma / NRGlab
// Ported from FlexAIDdS shannon_configurational_entropy with identical math.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cassert>
#include <cmath>

namespace shannon::kernels {

// ─── Configurational entropy (log-sum-exp) ────────────────────────────────────
//
// Given unnormalized log-weights w_i, the entropy in bits is:
//   H = log2(Z) - (1/Z) * Σ_i [ (w_i - max_w) * exp(w_i - max_w) ] / ln(2)
// where Z = Σ_i exp(w_i - max_w)

double configurational_entropy_scalar(const double* w, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;

    // Step 1: find max for log-sum-exp stability
    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    // Step 2: compute partition function Z and weighted sum
    double Z = 0.0;
    double weighted_sum = 0.0;

    for (std::size_t i = 0; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double exp_val = std::exp(shifted);
        Z += exp_val;
        weighted_sum += shifted * exp_val;
    }

    if (Z <= 0.0) return 0.0;

    // Step 3: entropy in bits
    const double log2_Z = std::log2(Z);
    const double entropy = log2_Z - (weighted_sum / (Z * kLn2));

    return std::fmax(0.0, entropy);
}

// ─── Shannon entropy from probabilities ───────────────────────────────────────

double entropy_from_probs_scalar(const double* p, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;

    double h = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon) {
            h -= p[i] * std::log2(p[i]);
        }
    }
    return std::fmax(0.0, h);
}

// ─── Shannon entropy from log-probabilities ───────────────────────────────────

double entropy_from_logprobs_scalar(const double* lp, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;

#ifndef NDEBUG
    double Z = 0.0;
    for (std::size_t i = 0; i < n; ++i) Z += std::exp(lp[i]);
    assert(std::abs(Z - 1.0) < 1e-4 && "entropy_from_logprobs: input not normalized");
#endif

    double h = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) {
            h -= p * lp[i] * kLog2E;  // nats → bits
        }
    }
    return std::fmax(0.0, h);
}

}  // namespace shannon::kernels
