// collapse_detector.hpp — Expanded sliding-window collapse detector for Shannon 2.0
//
// Uses the unified dispatch for backend selection. Tracks entropy over a
// sliding window, computes z-score delta, and fires callbacks on collapse.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/types.hpp"
#include "shannon/config.hpp"
#include "shannon/unified_dispatch.hpp"

#include <cstddef>
#include <functional>
#include <vector>

namespace shannon {

class CollapseDetector {
public:
    explicit CollapseDetector(
        std::size_t window_size = kDefaultWindowSize,
        double threshold_bits  = kDefaultCollapseThreshold);

    // Feed logits (unnormalized log-weights) — main entry point
    CollapseResult add_logits(const double* logits, std::size_t n);
    CollapseResult add_logits(std::span<const double> logits);

    // Feed probability distribution
    CollapseResult add_probs(const double* probs, std::size_t n);
    CollapseResult add_probs(std::span<const double> probs);

    // Feed log-probabilities
    CollapseResult add_logprobs(const double* logprobs, std::size_t n);
    CollapseResult add_logprobs(std::span<const double> logprobs);

    // Feed pre-computed entropy value directly
    CollapseResult push_entropy(double h);

    // Configuration
    void set_callback(CollapseCallback cb);
    void set_window_size(std::size_t size);
    void set_threshold(double threshold_bits);
    void reset();

    // Accessors
    std::size_t token_count() const noexcept;
    const std::vector<double>& entropy_trace() const noexcept;

private:
    std::size_t window_size_;
    double threshold_;
    std::vector<double> window_;
    std::size_t window_pos_ = 0;
    bool window_full_ = false;
    std::size_t token_count_ = 0;
    std::vector<double> trace_;
    CollapseCallback callback_;
};

}  // namespace shannon
