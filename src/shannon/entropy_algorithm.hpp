// entropy_algorithm.hpp — ISA-traits entropy kernels (log-sum-exp / H(p) / H(logp))
//
// One algorithm, many vector backends. Each ISA TU defines a Traits type and
// instantiates the templates below. Custom simd_exp.hpp / simd_log2.hpp must
// be used for SIMD Traits::exp / Traits::log2 — not scalar std::exp per lane
// (SSE4.2 is the exception: it has no vector exp, so Traits::exp calls libm).
// OpenMP stays a reduction specialization in entropy_omp.cpp (not a vector
// traits backend).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/config.hpp"

#include <cmath>
#include <cstddef>
#include <limits>
#include <span>

namespace shannon::kernels {

// Traits contract (all members static, noexcept):
//   using vec = <vector register type>;
//   static constexpr std::size_t width;     // lanes in vec; must be >= 1
//   static vec set1(double x);
//   static vec zero();
//   static vec load(const double* p);       // unaligned
//   static vec sub(vec a, vec b);
//   static vec add(vec a, vec b);
//   static vec mul(vec a, vec b);
//   static vec fmadd(vec a, vec b, vec c);  // a * b + c  (mul+add OK if no FMA)
//   static vec exp(vec x);                  // shannon_exp_* (SSE: libm per lane)
//   static vec log2(vec x);                 // shannon_log2_* (scalar: std::log2)
//   static vec select_gt(vec values, double threshold, vec if_true);
//   static vec select_finite(vec x, vec v); // v where x is finite, else 0
//   static double hsum(vec v);
//
// log2 / mul / select_gt are required only for H(p) / H(logp) instantiations.
// select_finite keeps -inf / NaN logits from producing 0*-inf NaNs in ws
// (masked-vocab false collapse: H became 0 via fmax(0, NaN)).

template <typename Traits>
[[nodiscard]] inline double configurational_entropy(std::span<const double> weights) noexcept {
    const double* w = weights.data();
    const std::size_t n = weights.size();
    if (n <= 1) return 0.0;

    double max_w = -std::numeric_limits<double>::infinity();
    bool any_finite = false;
    for (std::size_t i = 0; i < n; ++i) {
        if (std::isfinite(w[i])) {
            any_finite = true;
            if (w[i] > max_w) max_w = w[i];
        }
    }
    if (!any_finite) return 0.0;

    using vec = typename Traits::vec;
    const vec v_max = Traits::set1(max_w);
    vec acc_Z = Traits::zero();
    vec acc_ws = Traits::zero();

    std::size_t i = 0;
    constexpr std::size_t W = Traits::width;
    for (; i + W <= n; i += W) {
        const vec vw = Traits::load(w + i);
        const vec sh = Traits::sub(vw, v_max);
        const vec sh_f = Traits::select_finite(sh, sh);
        const vec ev = Traits::select_finite(sh, Traits::exp(sh));
        acc_Z = Traits::add(acc_Z, ev);
        acc_ws = Traits::fmadd(sh_f, ev, acc_ws);
    }

    double Z = Traits::hsum(acc_Z);
    double ws = Traits::hsum(acc_ws);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        if (!std::isfinite(shifted)) continue;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

template <typename Traits>
[[nodiscard]] inline double entropy_from_probs(std::span<const double> probs) noexcept {
    const double* p = probs.data();
    const std::size_t n = probs.size();
    if (n <= 1) return 0.0;

    using vec = typename Traits::vec;
    vec acc = Traits::zero();

    std::size_t i = 0;
    constexpr std::size_t W = Traits::width;
    for (; i + W <= n; i += W) {
        const vec vp = Traits::load(p + i);
        // contrib = -p * log2(p); zero where p <= kEpsilon (matches scalar).
        const vec contrib = Traits::mul(Traits::sub(Traits::zero(), vp), Traits::log2(vp));
        acc = Traits::add(acc, Traits::select_gt(vp, kEpsilon, contrib));
    }

    double h = Traits::hsum(acc);
    for (; i < n; ++i) {
        if (p[i] > kEpsilon) h -= p[i] * std::log2(p[i]);
    }
    return std::fmax(0.0, h);
}

template <typename Traits>
[[nodiscard]] inline double entropy_from_logprobs(std::span<const double> logprobs) noexcept {
    const double* lp = logprobs.data();
    const std::size_t n = logprobs.size();
    if (n <= 1) return 0.0;

    using vec = typename Traits::vec;
    vec acc = Traits::zero();

    std::size_t i = 0;
    constexpr std::size_t W = Traits::width;
    for (; i + W <= n; i += W) {
        const vec vlp = Traits::load(lp + i);
        const vec p = Traits::exp(vlp);
        // contrib = -p * lp * log2e  (>= 0 since lp <= 0); zero where p <= eps
        const vec contrib = Traits::mul(Traits::mul(p, vlp), Traits::set1(-kLog2E));
        acc = Traits::add(acc, Traits::select_gt(p, kEpsilon, contrib));
    }

    double h = Traits::hsum(acc);
    for (; i < n; ++i) {
        const double p = std::exp(lp[i]);
        if (p > kEpsilon) h -= p * lp[i] * kLog2E;
    }
    return std::fmax(0.0, h);
}

}  // namespace shannon::kernels
