// collapse_detector.hpp — Sliding-window entropy event detector for Shannon 2.0
//
// Detects three classes of entropy anomaly:
//   COLLAPSE    — entropy drops below threshold (ordering / lock-in)
//   EXPANSION   — entropy rises above threshold (disordering / release)
//   OSCILLATION — rapid alternation between collapse and expansion
//
// Uses the unified dispatch for backend selection. Tracks entropy over a
// sliding window, computes z-score delta, and fires callbacks on events.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/types.hpp"
#include "shannon/config.hpp"
#include "shannon/unified_dispatch.hpp"

#include <cstddef>
#include <deque>
#include <functional>
#include <vector>

namespace shannon {

class CollapseDetector {
public:
    explicit CollapseDetector(
        std::size_t window_size = kDefaultWindowSize,
        double collapse_threshold = kDefaultCollapseThreshold,
        double expansion_threshold = kDefaultExpansionThreshold,
        std::size_t oscillation_window = kDefaultOscillationWindow);

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
    void set_collapse_threshold(double threshold_bits);
    void set_expansion_threshold(double threshold_bits);
    void set_oscillation_window(std::size_t size);
    void set_max_trace_size(std::size_t max_size);
    void reset();

    // Legacy compat
    void set_threshold(double threshold_bits);

    // Accessors
    std::size_t token_count() const noexcept;
    const std::deque<double>& entropy_trace() const noexcept;

private:
    static constexpr std::size_t MAX_TRACE = 10000;  // hard cap: prevents unbounded growth

    std::size_t window_size_;
    double collapse_threshold_;
    double expansion_threshold_;
    std::size_t oscillation_window_;
    std::vector<double> window_;
    std::size_t window_pos_ = 0;
    bool window_full_ = false;
    std::size_t token_count_ = 0;
    std::size_t max_trace_size_ = MAX_TRACE;
    std::deque<double> trace_;
    std::vector<EntropyEvent> event_history_;
    CollapseCallback callback_;

    EntropyEvent classify_event(double delta, bool window_ready) const;
    bool detect_oscillation() const;
};

}  // namespace shannon
