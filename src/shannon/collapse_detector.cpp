// collapse_detector.cpp — Sliding-window entropy event detector
//
// Detects collapse, expansion, and oscillation in LLM token entropy.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/collapse_detector.hpp"

#include <algorithm>
#include <cmath>

namespace shannon {

CollapseDetector::CollapseDetector(
    std::size_t window_size,
    double collapse_threshold,
    double expansion_threshold,
    std::size_t oscillation_window)
    : window_size_(window_size > 0 ? window_size : kDefaultWindowSize)
    , collapse_threshold_(collapse_threshold)
    , expansion_threshold_(expansion_threshold > 0 ? expansion_threshold : -collapse_threshold)
    , oscillation_window_(oscillation_window > 0 ? oscillation_window : kDefaultOscillationWindow)
    , window_(window_size_, 0.0)
    , event_history_(oscillation_window_, EntropyEvent::NONE) {}

void CollapseDetector::reset() {
    trace_.clear();
    std::fill(window_.begin(), window_.end(), 0.0);
    std::fill(event_history_.begin(), event_history_.end(), EntropyEvent::NONE);
    window_pos_ = 0;
    window_full_ = false;
    token_count_ = 0;
}

CollapseResult CollapseDetector::add_logits(const double* logits, std::size_t n) {
    auto& dispatch = dispatch::UnifiedDispatch::instance();

    double h = 0.0;
    auto result = dispatch.compute_configurational_entropy(logits, n, h);

    CollapseResult cr = push_entropy(h);
    cr.used_backend = result.used_backend;
    return cr;
}

CollapseResult CollapseDetector::add_logits(std::span<const double> logits) {
    return add_logits(logits.data(), logits.size());
}

CollapseResult CollapseDetector::add_probs(const double* probs, std::size_t n) {
    auto& dispatch = dispatch::UnifiedDispatch::instance();

    double h = 0.0;
    auto result = dispatch.compute_entropy_from_probs(probs, n, h);

    CollapseResult cr = push_entropy(h);
    cr.used_backend = result.used_backend;
    return cr;
}

CollapseResult CollapseDetector::add_probs(std::span<const double> probs) {
    return add_probs(probs.data(), probs.size());
}

CollapseResult CollapseDetector::add_logprobs(const double* logprobs, std::size_t n) {
    auto& dispatch = dispatch::UnifiedDispatch::instance();

    double h = 0.0;
    auto result = dispatch.compute_entropy_from_logprobs(logprobs, n, h);

    CollapseResult cr = push_entropy(h);
    cr.used_backend = result.used_backend;
    return cr;
}

CollapseResult CollapseDetector::add_logprobs(std::span<const double> logprobs) {
    return add_logprobs(logprobs.data(), logprobs.size());
}

EntropyEvent CollapseDetector::classify_event(double delta, bool window_ready) const {
    if (!window_ready) return EntropyEvent::NONE;
    if (delta < collapse_threshold_) return EntropyEvent::COLLAPSE;
    if (delta > expansion_threshold_) return EntropyEvent::EXPANSION;
    return EntropyEvent::NONE;
}

bool CollapseDetector::detect_oscillation() const {
    int alternations = 0;
    for (std::size_t i = 1; i < event_history_.size(); ++i) {
        EntropyEvent prev = event_history_[i - 1];
        EntropyEvent curr = event_history_[i];
        if ((prev == EntropyEvent::COLLAPSE && curr == EntropyEvent::EXPANSION) ||
            (prev == EntropyEvent::EXPANSION && curr == EntropyEvent::COLLAPSE)) {
            ++alternations;
        }
    }
    return alternations >= 2;
}

CollapseResult CollapseDetector::push_entropy(double h) {
    trace_.push_back(h);
    if (max_trace_size_ > 0 && trace_.size() > max_trace_size_) {
        trace_.erase(trace_.begin(), trace_.begin() + (trace_.size() - max_trace_size_));
    }

    window_[window_pos_] = h;
    window_pos_ = (window_pos_ + 1) % window_size_;
    if (!window_full_ && window_pos_ == 0) {
        window_full_ = true;
    }

    const std::size_t count = window_full_ ? window_size_ : window_pos_;

    // Welford: O(n), stable. Replaces E[X²]-E[X]² which cancels catastrophically near H≈2 bits.
    double mean = 0.0, M2 = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        const double delta = window_[i] - mean;
        mean += delta / static_cast<double>(i + 1);
        const double delta2 = window_[i] - mean;
        M2 += delta * delta2;
    }
    const double variance = (count > 1) ? M2 / static_cast<double>(count - 1) : 0.0;
    const double stddev = std::sqrt(std::max(0.0, variance));

    const double delta = h - mean;
    const double z = (stddev > 1e-12) ? delta / stddev : 0.0;
    const bool window_ready = (count >= window_size_);

    EntropyEvent event = classify_event(delta, window_ready);

    event_history_[token_count_ % oscillation_window_] = event;
    bool oscillating = false;
    if (window_ready && event != EntropyEvent::NONE) {
        oscillating = detect_oscillation();
    }
    if (oscillating) {
        event = EntropyEvent::OSCILLATION;
    }

    CollapseResult result{
        .entropy     = h,
        .window_mean = mean,
        .window_std  = stddev,
        .delta       = delta,
        .z_score     = z,
        .collapsed   = (event == EntropyEvent::COLLAPSE),
        .expanded    = (event == EntropyEvent::EXPANSION),
        .oscillating = oscillating,
        .event       = event,
        .token_index = token_count_,
        .used_backend = Backend::SCALAR,
    };

    ++token_count_;

    if ((result.collapsed || result.expanded || result.oscillating) && callback_) {
        callback_(result);
    }

    return result;
}

void CollapseDetector::set_callback(CollapseCallback cb) {
    callback_ = std::move(cb);
}

void CollapseDetector::set_window_size(std::size_t size) {
    window_size_ = (size > 0) ? size : kDefaultWindowSize;
    window_.assign(window_size_, 0.0);
    window_pos_ = 0;
    window_full_ = false;
}

void CollapseDetector::set_collapse_threshold(double threshold_bits) {
    collapse_threshold_ = threshold_bits;
}

void CollapseDetector::set_expansion_threshold(double threshold_bits) {
    expansion_threshold_ = threshold_bits;
}

void CollapseDetector::set_oscillation_window(std::size_t size) {
    oscillation_window_ = (size > 0) ? size : kDefaultOscillationWindow;
    event_history_.assign(oscillation_window_, EntropyEvent::NONE);
}

void CollapseDetector::set_threshold(double threshold_bits) {
    collapse_threshold_ = threshold_bits;
}

void CollapseDetector::set_max_trace_size(std::size_t max_size) {
    max_trace_size_ = max_size;
    if (max_trace_size_ > 0 && trace_.size() > max_trace_size_) {
        trace_.erase(trace_.begin(), trace_.begin() + (trace_.size() - max_trace_size_));
    }
}

std::size_t CollapseDetector::token_count() const noexcept {
    return token_count_;
}

const std::vector<double>& CollapseDetector::entropy_trace() const noexcept {
    return trace_;
}

}  // namespace shannon
