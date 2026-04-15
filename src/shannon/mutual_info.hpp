// mutual_info.hpp — Inter-token mutual information I(X_t; X_{t+1})
//
// Computes the pointwise mutual information between consecutive token
// distributions in an LLM generation stream. High MI indicates the model
// is "locked in" to a predictable trajectory (potential deceptive alignment
// or evaluation-awareness signal).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/config.hpp"
#include "shannon/types.hpp"

#include <cstddef>
#include <optional>
#include <span>
#include <vector>

namespace shannon {

inline constexpr double kDefaultMIThreshold = 2.0;

struct MIResult {
    double mi_bits        = 0.0;
    double entropy_t      = 0.0;
    double entropy_t1     = 0.0;
    double kl_forward     = 0.0;
    double kl_reverse     = 0.0;
    double js_divergence  = 0.0;
    std::size_t token_index = 0;
    Backend used_backend  = Backend::SCALAR;
};

class MutualInfoTracker {
public:
    explicit MutualInfoTracker(
        std::size_t window_size = kDefaultWindowSize,
        double mi_threshold = kDefaultMIThreshold);

    MIResult add_probs(const double* probs, std::size_t n);
    MIResult add_probs(std::span<const double> probs);

    MIResult add_logprobs(const double* logprobs, std::size_t n);
    MIResult add_logprobs(std::span<const double> logprobs);

    MIResult add_logits(const double* logits, std::size_t n);
    MIResult add_logits(std::span<const double> logits);

    MIResult push_mi(double mi_bits);

    void set_window_size(std::size_t size);
    void set_mi_threshold(double threshold_bits);
    void set_max_trace_size(std::size_t max_size);
    void reset();

    std::size_t token_count() const noexcept;
    const std::vector<double>& mi_trace() const noexcept;
    double window_mean() const noexcept;
    double window_std() const noexcept;
    double current_mi() const noexcept;
    bool is_high_mi() const noexcept;

private:
    std::vector<double> softmax(const double* logits, std::size_t n) const;
    void update_window(double mi);

    std::size_t window_size_;
    double mi_threshold_;
    std::size_t max_trace_size_ = 0;
    std::vector<double> window_;
    std::size_t window_pos_ = 0;
    bool window_full_ = false;
    std::size_t token_count_ = 0;
    std::vector<double> trace_;
    std::vector<double> prev_probs_;
    double current_mi_ = 0.0;
    double window_mean_ = 0.0;
    double window_std_ = 0.0;
};

}  // namespace shannon

namespace shannon::kernels {

[[nodiscard]] double kl_divergence_scalar(
    const double* p, const double* q, std::size_t n) noexcept;

[[nodiscard]] double js_divergence_scalar(
    const double* p, const double* q, std::size_t n) noexcept;

[[nodiscard]] double cross_entropy_scalar(
    const double* p, const double* q, std::size_t n) noexcept;

#if defined(SHANNON_USE_OPENMP)
[[nodiscard]] double kl_divergence_omp(
    const double* p, const double* q, std::size_t n) noexcept;

[[nodiscard]] double js_divergence_omp(
    const double* p, const double* q, std::size_t n) noexcept;

[[nodiscard]] double cross_entropy_omp(
    const double* p, const double* q, std::size_t n) noexcept;
#endif

}  // namespace shannon::kernels
