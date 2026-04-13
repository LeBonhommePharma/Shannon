// collapse_detector.cpp — Expanded sliding-window collapse detector
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/collapse_detector.hpp"

#include <algorithm>
#include <cmath>

namespace shannon {

CollapseDetector::CollapseDetector(std::size_t window_size, double threshold_bits)
    : window_size_(window_size > 0 ? window_size : kDefaultWindowSize)
    , threshold_(threshold_bits)
    , window_(window_size_, 0.0) {}

void CollapseDetector::reset() {
    trace_.clear();
    std::fill(window_.begin(), window_.end(), 0.0);
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

CollapseResult CollapseDetector::push_entropy(double h) {
    trace_.push_back(h);

    // Update circular buffer
    window_[window_pos_] = h;
    window_pos_ = (window_pos_ + 1) % window_size_;
    if (!window_full_ && window_pos_ == 0) {
        window_full_ = true;
    }

    // Compute window statistics
    const std::size_t count = window_full_ ? window_size_ : window_pos_;
    double sum = 0.0;
    double sum_sq = 0.0;

    for (std::size_t i = 0; i < count; ++i) {
        sum += window_[i];
        sum_sq += window_[i] * window_[i];
    }

    const double mean = (count > 0) ? sum / static_cast<double>(count) : 0.0;
    const double variance = (count > 1)
        ? (sum_sq / static_cast<double>(count)) - (mean * mean)
        : 0.0;
    const double stddev = std::sqrt(std::max(0.0, variance));

    const double delta = h - mean;
    const double z = (stddev > 1e-12) ? delta / stddev : 0.0;
    const bool collapsed = (count >= window_size_) && (delta < threshold_);

    CollapseResult result{
        .entropy     = h,
        .window_mean = mean,
        .window_std  = stddev,
        .delta       = delta,
        .z_score     = z,
        .collapsed   = collapsed,
        .token_index = token_count_,
        .used_backend = Backend::SCALAR,  // Overwritten by caller if dispatched
    };

    ++token_count_;

    if (collapsed && callback_) {
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

void CollapseDetector::set_threshold(double threshold_bits) {
    threshold_ = threshold_bits;
}

std::size_t CollapseDetector::token_count() const noexcept {
    return token_count_;
}

const std::vector<double>& CollapseDetector::entropy_trace() const noexcept {
    return trace_;
}

}  // namespace shannon
