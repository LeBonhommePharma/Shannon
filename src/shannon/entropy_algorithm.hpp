// entropy_algorithm.hpp — ISA-traits configurational entropy (log-sum-exp)
//
// One algorithm, many vector backends. Each ISA TU defines a Traits type and
// instantiates configurational_entropy<Traits>. This is the Phase A.2 /
// ENH-035 first slice: configurational entropy only. H(p) / H(logp) and
// remaining ISAs (AVX-512, NEON, SSE, scalar width=1) stay hand-written until
// follow-up PRs. Custom simd_exp.hpp must be used for Traits::exp — not
// scalar std::exp per lane.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/config.hpp"

#include <cmath>
#include <cstddef>
#include <span>

namespace shannon::kernels {

// Traits contract (all members static, noexcept):
//   using vec = <vector register type>;
//   static constexpr std::size_t width;   // lanes in vec; must be >= 1
//   static vec set1(double x);
//   static vec zero();
//   static vec load(const double* p);     // unaligned
//   static vec sub(vec a, vec b);
//   static vec add(vec a, vec b);
//   static vec fmadd(vec a, vec b, vec c);  // a * b + c
//   static vec exp(vec x);                // shannon_exp_*, not std::exp
//   static double hsum(vec v);
//
// Max reduction and the scalar tail use libm (matches today's AVX2 kernel).
// The vector body must stay bit-identical to the hand-written ISA ops.

template <typename Traits>
[[nodiscard]] inline double configurational_entropy(std::span<const double> weights) noexcept {
    const double* w = weights.data();
    const std::size_t n = weights.size();
    if (n <= 1) return 0.0;

    double max_w = w[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (w[i] > max_w) max_w = w[i];
    }

    using vec = typename Traits::vec;
    const vec v_max = Traits::set1(max_w);
    vec acc_Z = Traits::zero();
    vec acc_ws = Traits::zero();

    std::size_t i = 0;
    constexpr std::size_t W = Traits::width;
    for (; i + W <= n; i += W) {
        const vec vw = Traits::load(w + i);
        const vec sh = Traits::sub(vw, v_max);
        const vec ev = Traits::exp(sh);
        acc_Z = Traits::add(acc_Z, ev);
        acc_ws = Traits::fmadd(sh, ev, acc_ws);
    }

    double Z = Traits::hsum(acc_Z);
    double ws = Traits::hsum(acc_ws);

    for (; i < n; ++i) {
        const double shifted = w[i] - max_w;
        const double ev = std::exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    if (Z <= 0.0) return 0.0;
    return std::fmax(0.0, std::log2(Z) - (ws / (Z * kLn2)));
}

}  // namespace shannon::kernels
