// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// Core Shannon entropy kernels — ported from FlexAID∆S
// (LIB/statmech.cpp · LIB/ShannonThermoStack/)
//
// The log-sum-exp numerically stable implementation preserves
// every pragma and optimisation from the molecular-docking kernel.

#include "shannon.hpp"
#include "shannon.h"  // v1 HardwareInfo / shannon_entropy bridges

#include <algorithm>
#include <cmath>
#include <numeric>

namespace shannon {

// ─── Configurational Entropy (log-sum-exp, OpenMP + SIMD) ────────────────────
//
// Ported directly from FlexAID∆S shannon_configurational_entropy.
// Given unnormalized log-weights w_i, the entropy in bits is:
//
//   S = log2(Z) - (1/Z) * sum_i [ w_i * exp(w_i - max_w) ] / ln(2)
//
// where Z = sum_i exp(w_i - max_w)  (log-sum-exp trick for stability).

double shannon_configurational_entropy(const double* log_weights, std::size_t n) {
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;

    // Step 1: find max for log-sum-exp stability
    double max_w = log_weights[0];
    #pragma omp simd reduction(max:max_w)
    for (std::size_t i = 1; i < n; ++i) {
        if (log_weights[i] > max_w) max_w = log_weights[i];
    }

    // Step 2: compute partition function Z and weighted sum
    double Z = 0.0;
    double weighted_sum = 0.0;

    #pragma omp parallel for simd reduction(+:Z,weighted_sum) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double shifted = log_weights[i] - max_w;
        const double exp_val = std::exp(shifted);
        Z += exp_val;
        weighted_sum += shifted * exp_val;  // (w_i - max_w) * exp(w_i - max_w)
    }

    if (Z <= 0.0) return 0.0;

    // Step 3: entropy in bits
    // H = log2(Z) - weighted_sum / (Z * ln2)
    const double log2_Z = std::log2(Z);
    const double entropy = log2_Z - (weighted_sum / (Z * kLn2));

    return std::max(0.0, entropy);
}

// ─── Entropy from Probability Distribution ───────────────────────────────────

double shannon_entropy_from_probs(const double* probs, std::size_t n) {
    if (n == 0) return 0.0;

    double h = 0.0;

    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        if (probs[i] > kEpsilon) {
            h -= probs[i] * std::log2(probs[i]);
        }
    }

    return std::max(0.0, h);
}

// ─── Entropy from Log-Probabilities ──────────────────────────────────────────

double shannon_entropy_from_logprobs(const double* logprobs, std::size_t n) {
    if (n == 0) return 0.0;

    double h = 0.0;

    #pragma omp parallel for simd reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        const double p = std::exp(logprobs[i]);
        if (p > kEpsilon) {
            h -= p * logprobs[i] * kLog2E;  // convert from nats to bits
        }
    }

    return std::max(0.0, h);
}

// ─── Collapse Detector ───────────────────────────────────────────────────────

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
    running_sum_ = 0.0;
    running_sum_sq_ = 0.0;
}

CollapseResult CollapseDetector::add_logits(const double* logits, std::size_t n) {
    return push_entropy(shannon_configurational_entropy(logits, n));
}

CollapseResult CollapseDetector::add_logits(std::span<const double> logits) {
    return add_logits(logits.data(), logits.size());
}

CollapseResult CollapseDetector::add_probs(const double* probs, std::size_t n) {
    return push_entropy(shannon_entropy_from_probs(probs, n));
}

CollapseResult CollapseDetector::add_probs(std::span<const double> probs) {
    return add_probs(probs.data(), probs.size());
}

CollapseResult CollapseDetector::add_logprobs(const double* logprobs, std::size_t n) {
    return push_entropy(shannon_entropy_from_logprobs(logprobs, n));
}

CollapseResult CollapseDetector::add_logprobs(std::span<const double> logprobs) {
    return add_logprobs(logprobs.data(), logprobs.size());
}

void CollapseDetector::set_callback(CollapseCallback cb) {
    callback_ = std::move(cb);
}

CollapseResult CollapseDetector::push_entropy(double h) {
    trace_.push_back(h);

    // Incremental update: subtract outgoing value before overwriting
    if (window_full_) {
        const double outgoing = window_[window_pos_];
        running_sum_ -= outgoing;
        running_sum_sq_ -= outgoing * outgoing;
    }

    // Update circular buffer
    window_[window_pos_] = h;
    window_pos_ = (window_pos_ + 1) % window_size_;
    if (!window_full_ && window_pos_ == 0) {
        window_full_ = true;
    }

    // Add incoming value
    running_sum_ += h;
    running_sum_sq_ += h * h;

    // Compute window statistics from running accumulators
    const std::size_t count = window_full_ ? window_size_ : window_pos_;

    const double mean = (count > 0) ? running_sum_ / static_cast<double>(count) : 0.0;
    const double variance = (count > 1)
        ? (running_sum_sq_ / static_cast<double>(count)) - (mean * mean)
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
    };

    ++token_count_;

    if (collapsed && callback_) {
        callback_(result);
    }

    return result;
}

// ─── Hardware info (v1 API used by Python bindings / CLI) ────────────────────

HardwareInfo get_hardware_info() {
    HardwareInfo info{};

#if defined(__AVX512F__)
    info.has_avx512 = true;
#endif
#if defined(__AVX2__)
    info.has_avx2 = true;
#endif
#if defined(__ARM_NEON) || defined(__aarch64__)
    info.has_neon = true;
#endif
#ifdef _OPENMP
    info.has_openmp = true;
#endif
    // GPU backends were removed; has_cuda/has_metal are retained as always-false
    // fields for v1 API/ABI stability (Python bindings + CLI still read them).

    // Prefer widest available backend (mirrors UnifiedDispatch priority)
    if (info.has_avx512)      info.active_backend = "avx512";
    else if (info.has_avx2)   info.active_backend = "avx2";
    else if (info.has_neon)   info.active_backend = "neon";
    else if (info.has_openmp) info.active_backend = "openmp";
    else                      info.active_backend = "scalar";

    return info;
}

// ─── v1 shannon.h API bridges (bindings expect these names) ──────────────────

double shannon_entropy(const double* probs, size_t n) {
    return shannon_entropy_from_probs(probs, n);
}

double shannon_entropy(std::span<const double> probs) {
    return shannon_entropy_from_probs(probs.data(), probs.size());
}

double shannon_entropy_from_logits(const double* logits, size_t n) {
    return shannon_configurational_entropy(logits, n);
}

double shannon_entropy_from_logits(std::span<const double> logits) {
    return shannon_configurational_entropy(logits.data(), logits.size());
}

EntropyResult compute_entropy(const double* probs, size_t n, double collapse_threshold) {
    EntropyResult r{};
    r.H = shannon_entropy_from_probs(probs, n);
    const double max_h = (n > 1) ? std::log2(static_cast<double>(n)) : 1.0;
    r.H_normalized = (max_h > 0.0) ? r.H / max_h : 0.0;
    r.collapsed = r.H_normalized < collapse_threshold;
    return r;
}

EntropyResult compute_entropy_from_logits(const double* logits, size_t n,
                                          double collapse_threshold) {
    EntropyResult r{};
    r.H = shannon_configurational_entropy(logits, n);
    const double max_h = (n > 1) ? std::log2(static_cast<double>(n)) : 1.0;
    r.H_normalized = (max_h > 0.0) ? r.H / max_h : 0.0;
    r.collapsed = r.H_normalized < collapse_threshold;
    return r;
}

// ─── SlidingWindowEntropy (v1 API used by Python bindings) ───────────────────

SlidingWindowEntropy::SlidingWindowEntropy(size_t window_size, double collapse_threshold)
    : window_size_(window_size > 0 ? window_size : 8)
    , collapse_threshold_(collapse_threshold)
    , regression_denom_(0.0) {
    precompute_regression_denom();
}

void SlidingWindowEntropy::precompute_regression_denom() {
    // Denominator for slope of ordinary least squares over indices 0..n-1:
    //   sum((i - mean_i)^2) = n*(n^2-1)/12
    const double n = static_cast<double>(window_size_);
    if (n < 2.0) {
        regression_denom_ = 1.0;
        return;
    }
    regression_denom_ = n * (n * n - 1.0) / 12.0;
    if (regression_denom_ < 1e-18) {
        regression_denom_ = 1.0;
    }
}

void SlidingWindowEntropy::push(double entropy_value) {
    buffer_.push_back(entropy_value);
    if (buffer_.size() > window_size_) {
        buffer_.pop_front();
    }
    trace_.push_back(entropy_value);

    if (is_collapsed() && on_collapse_) {
        CollapseEvent event{};
        event.token_index = trace_.size() - 1;
        event.entropy = entropy_value;
        event.delta_h = delta_h();
        event.collapse_score = collapse_score();
        on_collapse_(event);
    }
}

void SlidingWindowEntropy::push_logits(const double* logits, size_t n) {
    push(shannon_entropy_from_logits(logits, n));
}

double SlidingWindowEntropy::current_entropy() const {
    return buffer_.empty() ? 0.0 : buffer_.back();
}

double SlidingWindowEntropy::mean_entropy() const {
    if (buffer_.empty()) return 0.0;
    double sum = 0.0;
    for (double v : buffer_) sum += v;
    return sum / static_cast<double>(buffer_.size());
}

double SlidingWindowEntropy::delta_h() const {
    // OLS slope of entropy vs. token index over the current window.
    const size_t n = buffer_.size();
    if (n < 2) return 0.0;

    double mean_y = 0.0;
    for (double v : buffer_) mean_y += v;
    mean_y /= static_cast<double>(n);

    const double mean_x = 0.5 * static_cast<double>(n - 1);
    double numer = 0.0;
    double denom = 0.0;
    size_t i = 0;
    for (double y : buffer_) {
        const double dx = static_cast<double>(i) - mean_x;
        numer += dx * (y - mean_y);
        denom += dx * dx;
        ++i;
    }
    if (denom < 1e-18) return 0.0;
    return numer / denom;
}

bool SlidingWindowEntropy::is_collapsed() const {
    if (buffer_.size() < window_size_) return false;
    // collapse_threshold is typically negative (e.g. -3.2 bits/token).
    return delta_h() < collapse_threshold_;
}

double SlidingWindowEntropy::collapse_score() const {
    if (collapse_threshold_ >= 0.0 || std::abs(collapse_threshold_) < 1e-18) {
        return 0.0;
    }
    return std::abs(delta_h() / collapse_threshold_);
}

void SlidingWindowEntropy::reset() {
    buffer_.clear();
    trace_.clear();
}

void SlidingWindowEntropy::set_on_collapse(std::function<void(const CollapseEvent&)> callback) {
    on_collapse_ = std::move(callback);
}

}  // namespace shannon
