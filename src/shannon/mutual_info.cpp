// mutual_info.cpp — Inter-token mutual information I(X_t; X_{t+1})
//
// Scalar implementation of KL-divergence, cross-entropy, and Jensen-Shannon
// divergence kernels. MutualInfoTracker provides sliding-window MI tracking.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/mutual_info.hpp"
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace shannon::kernels {

double kl_divergence_scalar(const double* p, const double* q, std::size_t n) noexcept {
    if (n <= 1) return 0.0;
    if (!p || !q) return 0.0;

    double kl = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon && q[i] > kEpsilon) {
            kl += p[i] * std::log2(p[i] / q[i]);
        } else if (p[i] > kEpsilon && q[i] <= kEpsilon) {
            kl += p[i] * 30.0;
        }
    }
    return std::fmax(0.0, kl);
}

#if defined(SHANNON_USE_OPENMP)
double kl_divergence_omp(const double* p, const double* q, std::size_t n) noexcept {
    if (n <= 1) return 0.0;
    if (!p || !q) return 0.0;

    double kl = 0.0;
    #pragma omp parallel for reduction(+:kl) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon && q[i] > kEpsilon) {
            kl += p[i] * std::log2(p[i] / q[i]);
        } else if (p[i] > kEpsilon && q[i] <= kEpsilon) {
            kl += p[i] * 30.0;
        }
    }
    return std::fmax(0.0, kl);
}

double cross_entropy_omp(const double* p, const double* q, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (!p || !q) return 0.0;

    double h = 0.0;
    #pragma omp parallel for reduction(+:h) schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon && q[i] > kEpsilon) {
            h -= p[i] * std::log2(q[i]);
        }
    }
    return std::fmax(0.0, h);
}

double js_divergence_omp(const double* p, const double* q, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (!p || !q) return 0.0;

    std::vector<double> m(n);
    #pragma omp parallel for schedule(static)
    for (std::size_t i = 0; i < n; ++i) {
        m[i] = 0.5 * (p[i] + q[i]);
    }

    double jsd = 0.5 * (kl_divergence_omp(p, m.data(), n) + kl_divergence_omp(q, m.data(), n));
    return std::fmax(0.0, jsd);
}
#endif

double cross_entropy_scalar(const double* p, const double* q, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (!p || !q) return 0.0;

    double h = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        if (p[i] > kEpsilon && q[i] > kEpsilon) {
            h -= p[i] * std::log2(q[i]);
        }
    }
    return std::fmax(0.0, h);
}

double js_divergence_scalar(const double* p, const double* q, std::size_t n) noexcept {
    if (n == 0) return 0.0;
    if (!p || !q) return 0.0;

    std::vector<double> m(n);
    for (std::size_t i = 0; i < n; ++i) {
        m[i] = 0.5 * (p[i] + q[i]);
    }

    double jsd = 0.5 * (kl_divergence_scalar(p, m.data(), n) + kl_divergence_scalar(q, m.data(), n));
    return std::fmax(0.0, jsd);
}

}  // namespace shannon::kernels

namespace shannon {

MutualInfoTracker::MutualInfoTracker(std::size_t window_size, double mi_threshold)
    : window_size_(window_size > 0 ? window_size : kDefaultWindowSize)
    , mi_threshold_(mi_threshold)
    , window_(window_size_, 0.0) {}

void MutualInfoTracker::reset() {
    trace_.clear();
    std::fill(window_.begin(), window_.end(), 0.0);
    window_pos_ = 0;
    window_full_ = false;
    token_count_ = 0;
    prev_probs_.clear();
    current_mi_ = 0.0;
    window_mean_ = 0.0;
    window_std_ = 0.0;
}

std::vector<double> MutualInfoTracker::softmax(const double* logits, std::size_t n) const {
    if (n == 0) return {};

    double max_val = logits[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (logits[i] > max_val) max_val = logits[i];
    }

    std::vector<double> probs(n);
    double sum = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        probs[i] = std::exp(logits[i] - max_val);
        sum += probs[i];
    }
    if (sum > 0.0) {
        for (std::size_t i = 0; i < n; ++i) {
            probs[i] /= sum;
        }
    }
    return probs;
}

void MutualInfoTracker::update_window(double mi) {
    window_[window_pos_] = mi;
    window_pos_ = (window_pos_ + 1) % window_size_;
    if (!window_full_ && window_pos_ == 0) {
        window_full_ = true;
    }

    const std::size_t count = window_full_ ? window_size_ : window_pos_;
    if (count == 0) {
        window_mean_ = 0.0;
        window_std_ = 0.0;
        return;
    }

    double sum = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        sum += window_[i];
    }
    window_mean_ = sum / static_cast<double>(count);

    double sum_sq_diff = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        const double diff = window_[i] - window_mean_;
        sum_sq_diff += diff * diff;
    }
    const double variance = (count > 1)
        ? sum_sq_diff / static_cast<double>(count)
        : 0.0;
    window_std_ = std::sqrt(std::max(0.0, variance));
}

MIResult MutualInfoTracker::add_probs(const double* probs, std::size_t n) {
    if (!probs || n == 0) {
        return MIResult{};
    }

    MIResult result;
    result.token_index = token_count_;

    if (prev_probs_.empty()) {
        prev_probs_.assign(probs, probs + n);
        result.entropy_t = kernels::entropy_from_probs_scalar(probs, n);
        result.entropy_t1 = result.entropy_t;
        ++token_count_;
        return result;
    }

    const std::size_t dim = std::min(prev_probs_.size(), n);
    result.entropy_t = kernels::entropy_from_probs_scalar(prev_probs_.data(), dim);
    result.entropy_t1 = kernels::entropy_from_probs_scalar(probs, dim);

    result.kl_forward = kernels::kl_divergence_scalar(probs, prev_probs_.data(), dim);
    result.kl_reverse = kernels::kl_divergence_scalar(prev_probs_.data(), probs, dim);

    std::vector<double> m(dim);
    for (std::size_t i = 0; i < dim; ++i) {
        m[i] = 0.5 * (prev_probs_[i] + probs[i]);
    }
    double h_m = kernels::entropy_from_probs_scalar(m.data(), dim);
    result.js_divergence = result.entropy_t - h_m + 0.5 * (kernels::cross_entropy_scalar(probs, m.data(), dim) - result.entropy_t1);

    result.js_divergence = std::fmax(0.0, result.js_divergence);

    result.mi_bits = result.kl_forward;

    current_mi_ = result.mi_bits;
    update_window(result.mi_bits);

    prev_probs_.assign(probs, probs + n);

    if (max_trace_size_ > 0 && trace_.size() >= max_trace_size_) {
        trace_.erase(trace_.begin(), trace_.begin() + (trace_.size() - max_trace_size_ + 1));
    }
    trace_.push_back(result.mi_bits);

    result.used_backend = Backend::SCALAR;
    ++token_count_;
    return result;
}

MIResult MutualInfoTracker::add_probs(std::span<const double> probs) {
    return add_probs(probs.data(), probs.size());
}

MIResult MutualInfoTracker::add_logprobs(const double* logprobs, std::size_t n) {
    if (!logprobs || n == 0) return MIResult{};

    std::vector<double> probs(n);
    for (std::size_t i = 0; i < n; ++i) {
        probs[i] = std::exp(logprobs[i]);
    }
    return add_probs(probs.data(), n);
}

MIResult MutualInfoTracker::add_logprobs(std::span<const double> logprobs) {
    return add_logprobs(logprobs.data(), logprobs.size());
}

MIResult MutualInfoTracker::add_logits(const double* logits, std::size_t n) {
    if (!logits || n == 0) return MIResult{};
    auto probs = softmax(logits, n);
    return add_probs(probs.data(), probs.size());
}

MIResult MutualInfoTracker::add_logits(std::span<const double> logits) {
    return add_logits(logits.data(), logits.size());
}

MIResult MutualInfoTracker::push_mi(double mi_bits) {
    MIResult result;
    result.mi_bits = mi_bits;
    result.token_index = token_count_;

    current_mi_ = mi_bits;
    update_window(mi_bits);

    if (max_trace_size_ > 0 && trace_.size() >= max_trace_size_) {
        trace_.erase(trace_.begin(), trace_.begin() + (trace_.size() - max_trace_size_ + 1));
    }
    trace_.push_back(mi_bits);

    ++token_count_;
    return result;
}

void MutualInfoTracker::set_window_size(std::size_t size) {
    window_size_ = (size > 0) ? size : kDefaultWindowSize;
    window_.assign(window_size_, 0.0);
    window_pos_ = 0;
    window_full_ = false;
}

void MutualInfoTracker::set_mi_threshold(double threshold_bits) {
    mi_threshold_ = threshold_bits;
}

void MutualInfoTracker::set_max_trace_size(std::size_t max_size) {
    max_trace_size_ = max_size;
    if (max_trace_size_ > 0 && trace_.size() > max_trace_size_) {
        trace_.erase(trace_.begin(), trace_.begin() + (trace_.size() - max_trace_size_));
    }
}

std::size_t MutualInfoTracker::token_count() const noexcept {
    return token_count_;
}

const std::vector<double>& MutualInfoTracker::mi_trace() const noexcept {
    return trace_;
}

double MutualInfoTracker::window_mean() const noexcept {
    return window_mean_;
}

double MutualInfoTracker::window_std() const noexcept {
    return window_std_;
}

double MutualInfoTracker::current_mi() const noexcept {
    return current_mi_;
}

bool MutualInfoTracker::is_high_mi() const noexcept {
    if (!window_full_) return false;
    return current_mi_ > (window_mean_ + mi_threshold_);
}

}  // namespace shannon
