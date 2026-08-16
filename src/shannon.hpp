// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// Shannon Entropy Collapse Detection Library
// Ported from FlexAID∆S configurational entropy kernel
// (lmorency/FlexAIDdS — StatMechEngine / ShannonThermoStack)

#pragma once

#include <shannon/config.hpp>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <functional>
#include <limits>
#include <numeric>
#include <span>
#include <stdexcept>
#include <vector>

namespace shannon {

// ─── Core Kernel ─────────────────────────────────────────────────────────────
// Direct port of shannon_configurational_entropy from FlexAID∆S.
// Uses log-sum-exp for numerical stability, with OpenMP + SIMD pragmas.

/// Compute Shannon configurational entropy from unnormalized log-weights.
/// @param log_weights  array of log-weights (e.g. logits from an LLM)
/// @return             entropy in bits (always >= 0)
double shannon_configurational_entropy(std::span<const double> log_weights);

/// Pointer+size overload. `nullptr` with `n > 0` is defined as H = 0
/// (not UB).
inline double shannon_configurational_entropy(const double* log_weights, std::size_t n) {
    if (log_weights == nullptr || n == 0) return 0.0;
    return shannon_configurational_entropy(std::span<const double>{log_weights, n});
}

/// Compute Shannon entropy from a normalized probability distribution.
double shannon_entropy_from_probs(std::span<const double> probs);

inline double shannon_entropy_from_probs(const double* probs, std::size_t n) {
    if (probs == nullptr || n == 0) return 0.0;
    return shannon_entropy_from_probs(std::span<const double>{probs, n});
}

/// Compute Shannon entropy from log-probabilities (base e).
double shannon_entropy_from_logprobs(std::span<const double> logprobs);

inline double shannon_entropy_from_logprobs(const double* logprobs, std::size_t n) {
    if (logprobs == nullptr || n == 0) return 0.0;
    return shannon_entropy_from_logprobs(std::span<const double>{logprobs, n});
}

// ─── Sliding-Window Collapse Detector (legacy v1) ────────────────────────────
//
// Product detector: `shannon::CollapseDetector` in collapse_detector.hpp
// (Welford n−1, expansion/oscillation, UnifiedDispatch). Bindings, the
// Python twin, and shannon-agent use that class.
//
// This v1 detector is a separate implementation: OpenMP kernels, population
// variance (E[X²]−μ² with divisor n), collapse-only, unbounded trace. Do not
// wrap it around v2 — the window_std / z_score / edge-threshold .collapsed
// bits disagree. `namespace v1` is **not** inline so both headers can be
// included in one TU: `shannon::CollapseDetector` is always v2.
// Itanium mangling already included `v1` when this was an inline namespace.

namespace v1 {

/// Result from a single step of collapse detection.
struct CollapseResult {
    double entropy;           ///< Current token entropy (bits)
    double window_mean;       ///< Mean entropy over the window
    double window_std;        ///< Std-dev of entropy over the window
    double delta;             ///< entropy - window_mean (negative = collapse)
    double z_score;           ///< Standardised score (delta / std)
    bool   collapsed;         ///< True if delta < threshold
    std::size_t token_index;  ///< 0-based token counter
};

/// Callback type for collapse alerts.
using CollapseCallback = std::function<void(const CollapseResult&)>;

/// Streaming entropy collapse detector.
/// Maintains a sliding window and fires a callback on collapse events.
class CollapseDetector {
public:
    /// Construct with configurable window size and threshold.
    /// @param window_size      Number of past entropies to track (default 8)
    /// @param threshold_bits   Collapse threshold in bits (default -3.2)
    explicit CollapseDetector(
        std::size_t window_size    = kDefaultWindowSize,
        double      threshold_bits = kDefaultCollapseThreshold);

    /// Reset internal state.
    void reset();

    /// Feed unnormalized logits for the current token.
    CollapseResult add_logits(const double* logits, std::size_t n);
    CollapseResult add_logits(std::span<const double> logits);

    /// Feed a normalized probability distribution.
    CollapseResult add_probs(const double* probs, std::size_t n);
    CollapseResult add_probs(std::span<const double> probs);

    /// Feed log-probabilities (base e).
    CollapseResult add_logprobs(const double* logprobs, std::size_t n);
    CollapseResult add_logprobs(std::span<const double> logprobs);

    /// Feed a pre-computed entropy (same window math as add_*).
    CollapseResult push_entropy(double h);

    /// Register a callback invoked on every collapse event.
    void set_callback(CollapseCallback cb);

    /// Access the full entropy trace.
    const std::vector<double>& trace() const { return trace_; }

    /// Configuration accessors.
    std::size_t window_size()    const { return window_size_; }
    double      threshold_bits() const { return threshold_;   }

private:
    std::size_t           window_size_;
    double                threshold_;
    std::vector<double>   trace_;
    std::vector<double>   window_;
    std::size_t           window_pos_ = 0;
    bool                  window_full_ = false;
    std::size_t           token_count_ = 0;
    double                running_sum_ = 0.0;
    double                running_sum_sq_ = 0.0;
    CollapseCallback      callback_;
};

}  // namespace v1

}  // namespace shannon
