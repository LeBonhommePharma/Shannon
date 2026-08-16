// entropy_scalar.cpp — Scalar (baseline) entropy kernels
//
// Pure C++20 entropy collapse detection — Le Bonhomme Pharma / NRGlab
// Ported from FlexAIDdS shannon_configurational_entropy with identical math.
// Instantiated as width=1 traits over the shared algorithm.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"
#include "shannon/entropy_algorithm.hpp"
#include "shannon/config.hpp"

#include <cassert>
#include <cmath>

namespace shannon::kernels {

namespace {

struct ScalarTraits {
    using vec = double;
    static constexpr std::size_t width = 1;

    [[nodiscard]] static vec set1(double x) noexcept { return x; }
    [[nodiscard]] static vec zero() noexcept { return 0.0; }
    [[nodiscard]] static vec load(const double* p) noexcept { return *p; }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return a - b; }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return a + b; }
    [[nodiscard]] static vec mul(vec a, vec b) noexcept { return a * b; }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept { return a * b + c; }
    [[nodiscard]] static vec exp(vec x) noexcept { return std::exp(x); }
    [[nodiscard]] static vec log2(vec x) noexcept { return std::log2(x); }
    [[nodiscard]] static vec select_gt(vec values, double threshold, vec if_true) noexcept {
        return values > threshold ? if_true : 0.0;
    }
    [[nodiscard]] static vec select_finite(vec x, vec v) noexcept {
        return std::isfinite(x) ? v : 0.0;
    }
    [[nodiscard]] static double hsum(vec v) noexcept { return v; }
};

}  // namespace

double configurational_entropy_scalar(std::span<const double> weights) noexcept {
    return configurational_entropy<ScalarTraits>(weights);
}

double entropy_from_probs_scalar(std::span<const double> probs) noexcept {
    return entropy_from_probs<ScalarTraits>(probs);
}

double entropy_from_logprobs_scalar(std::span<const double> logprobs) noexcept {
#ifndef NDEBUG
    const double* lp = logprobs.data();
    const std::size_t n = logprobs.size();
    if (n > 1 && lp != nullptr) {
        double Z = 0.0;
        for (std::size_t i = 0; i < n; ++i) Z += std::exp(lp[i]);
        assert(std::abs(Z - 1.0) < 1e-4 && "entropy_from_logprobs: input not normalized");
    }
#endif
    return entropy_from_logprobs<ScalarTraits>(logprobs);
}

}  // namespace shannon::kernels
