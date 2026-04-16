// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// Shannon Entropy Collapse Detection Library
// Ported from FlexAID∆S configurational entropy kernel
// (lmorency/FlexAIDdS — StatMechEngine / ShannonThermoStack)

#pragma once

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

// ─── Constants ───────────────────────────────────────────────────────────────

inline constexpr double kLn2        = 0.693147180559945309417;
inline constexpr double kLog2E      = 1.44269504088896340736;
inline constexpr double kEpsilon    = 1e-300;
inline constexpr double kDefaultCollapseThreshold = -3.2; // bits
inline constexpr std::size_t kDefaultWindowSize   = 8;

// ─── Core Kernel ─────────────────────────────────────────────────────────────
// Direct port of shannon_configurational_entropy from FlexAID∆S.
// Uses log-sum-exp for numerical stability, with OpenMP + SIMD pragmas.

/// Compute Shannon configurational entropy from unnormalized log-weights.
/// @param log_weights  array of log-weights (e.g. logits from an LLM)
/// @param n            number of elements
/// @return             entropy in bits (always >= 0)
double shannon_configurational_entropy(const double* log_weights, std::size_t n);

/// Overload accepting a std::span for modern C++ usage.
inline double shannon_configurational_entropy(std::span<const double> log_weights) {
    return shannon_configurational_entropy(log_weights.data(), log_weights.size());
}

/// Compute Shannon entropy from a normalized probability distribution.
/// @param probs  array of probabilities (must sum to ~1)
/// @param n      number of elements
/// @return       entropy in bits
double shannon_entropy_from_probs(const double* probs, std::size_t n);

inline double shannon_entropy_from_probs(std::span<const double> probs) {
    return shannon_entropy_from_probs(probs.data(), probs.size());
}

/// Compute Shannon entropy from log-probabilities.
/// @param logprobs  array of log-probabilities (base e)
/// @param n         number of elements
/// @return          entropy in bits
double shannon_entropy_from_logprobs(const double* logprobs, std::size_t n);

inline double shannon_entropy_from_logprobs(std::span<const double> logprobs) {
    return shannon_entropy_from_logprobs(logprobs.data(), logprobs.size());
}

// ─── Sliding-Window Collapse Detector ────────────────────────────────────────

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

    /// Register a callback invoked on every collapse event.
    void set_callback(CollapseCallback cb);

    /// Access the full entropy trace.
    const std::vector<double>& trace() const { return trace_; }

    /// Configuration accessors.
    std::size_t window_size()    const { return window_size_; }
    double      threshold_bits() const { return threshold_;   }

private:
    CollapseResult push_entropy(double h);

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

}  // namespace shannon
