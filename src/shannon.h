#pragma once
// =============================================================================
// Shannon — Core Entropy Kernels for LLM Safeguarding
//
// Ported from FlexAIDdS ShannonThermoStack + StatMechEngine.
// Hardware acceleration: CUDA GPU -> Metal GPU -> AVX-512 -> AVX2 -> OpenMP -> scalar
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <span>
#include <string>
#include <vector>

namespace shannon {

// ─── Result types ────────────────────────────────────────────────────────────

struct EntropyResult {
    double H;              // Shannon entropy in bits
    double H_normalized;   // H / log2(n), in [0, 1]
    bool   collapsed;      // H_normalized < threshold
};

struct CollapseEvent {
    size_t token_index;    // position in the stream
    double entropy;        // entropy at this token
    double delta_h;        // rate of entropy change (bits/token)
    double collapse_score; // |delta_h / threshold|, >1.0 means collapsed
};

// ─── Core entropy functions ──────────────────────────────────────────────────

// H = -Σ p_i log2(p_i), convention 0·log(0) = 0
// SIMD-accelerated with runtime dispatch (AVX-512 → AVX2 → scalar)
double shannon_entropy(const double* probs, size_t n);
double shannon_entropy(std::span<const double> probs);

// From raw logits: fused log-sum-exp softmax + entropy
// No intermediate probability vector allocation
// Numerically stable via log-sum-exp trick from FlexAIDdS StatMechEngine
double shannon_entropy_from_logits(const double* logits, size_t n);
double shannon_entropy_from_logits(std::span<const double> logits);

// Full result with collapse detection
EntropyResult compute_entropy(const double* probs, size_t n,
                               double collapse_threshold = 0.1);
EntropyResult compute_entropy_from_logits(const double* logits, size_t n,
                                           double collapse_threshold = 0.1);

// ─── Sliding window entropy tracker ─────────────────────────────────────────

class SlidingWindowEntropy {
public:
    explicit SlidingWindowEntropy(size_t window_size = 8,
                                  double collapse_threshold = -3.2);

    // Push a new entropy value (computed externally or via add_logits)
    void push(double entropy_value);

    // Convenience: compute entropy from logits and push
    void push_logits(const double* logits, size_t n);

    // Current state
    double current_entropy() const;
    double mean_entropy() const;

    // Linear regression slope over the window (bits/token)
    double delta_h() const;

    // Collapse detection
    bool   is_collapsed() const;
    double collapse_score() const; // |delta_h / threshold|, >1 means collapsed

    // Full trace
    const std::vector<double>& entropy_trace() const { return trace_; }
    size_t token_count() const { return trace_.size(); }

    // Window contents
    const std::deque<double>& window() const { return buffer_; }

    void reset();

    // Alert callback (optional)
    void set_on_collapse(std::function<void(const CollapseEvent&)> callback);

private:
    size_t window_size_;
    double collapse_threshold_;
    std::deque<double> buffer_;
    std::vector<double> trace_;
    std::function<void(const CollapseEvent&)> on_collapse_;

    // Precomputed denominator for linear regression
    double regression_denom_;
    void precompute_regression_denom();
};

// ─── Hardware info ───────────────────────────────────────────────────────────

struct HardwareInfo {
    bool has_avx512;
    bool has_avx2;
    bool has_openmp;
    bool has_cuda;
    bool has_metal;
    std::string active_backend;  // "avx512", "avx2", "openmp", "scalar", "cuda", "metal"
};

HardwareInfo get_hardware_info();

}  // namespace shannon
