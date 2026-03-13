// =============================================================================
// Shannon — Core Entropy Kernels with Hardware-Accelerated Dispatch
//
// Ported from FlexAIDdS:
//   - ShannonThermoStack::compute_shannon_entropy() — histogram + SIMD
//   - StatMechEngine::compute() — log-sum-exp numerical stability
//
// Hardware priority: CUDA → Metal → AVX-512 → AVX2 → OpenMP → scalar
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include "shannon.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <numbers>

#ifdef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif

#ifdef SHANNON_HAS_AVX2
#ifndef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif
#endif

#ifdef SHANNON_HAS_OPENMP
#include <omp.h>
#endif

namespace shannon {

// =============================================================================
// Scalar fallback — always available
// =============================================================================

static double shannon_entropy_scalar(const double* probs, size_t n) {
    double H = 0.0;
#ifdef SHANNON_HAS_OPENMP
    if (n > 10000) {
        #pragma omp parallel for simd reduction(-:H)
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] > 0.0) {
                H -= probs[i] * std::log2(probs[i]);
            }
        }
    } else
#endif
    {
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] > 0.0) {
                H -= probs[i] * std::log2(probs[i]);
            }
        }
    }
    return H;
}

// =============================================================================
// AVX2 path — 4-wide double SIMD
// =============================================================================

#ifdef SHANNON_HAS_AVX2

static double shannon_entropy_avx2(const double* probs, size_t n) {
    __m256d acc = _mm256_setzero_pd();
    __m256d zero = _mm256_setzero_pd();

    size_t i = 0;
    const size_t vec_end = n - (n % 4);

    for (; i < vec_end; i += 4) {
        __m256d p = _mm256_loadu_pd(probs + i);

        // Mask: skip zero probabilities to avoid log(0) = -inf
        __m256d mask = _mm256_cmp_pd(p, zero, _CMP_GT_OQ);

        // log2(p) = log(p) * log2(e)
        // We compute log(p) via the identity: use cmath scalar per-lane
        // (AVX2 lacks native log intrinsic without SVML)
        alignas(32) double p_arr[4];
        alignas(32) double log2_arr[4];
        _mm256_store_pd(p_arr, p);

        for (int k = 0; k < 4; ++k) {
            log2_arr[k] = (p_arr[k] > 0.0) ? std::log2(p_arr[k]) : 0.0;
        }
        __m256d log2_p = _mm256_load_pd(log2_arr);

        // p * log2(p), masked
        __m256d plog = _mm256_mul_pd(p, log2_p);
        plog = _mm256_and_pd(plog, mask);

        acc = _mm256_sub_pd(acc, plog);
    }

    // Horizontal sum
    alignas(32) double result[4];
    _mm256_store_pd(result, acc);
    double H = result[0] + result[1] + result[2] + result[3];

    // Tail elements
    for (; i < n; ++i) {
        if (probs[i] > 0.0) {
            H -= probs[i] * std::log2(probs[i]);
        }
    }
    return H;
}

#endif  // SHANNON_HAS_AVX2

// =============================================================================
// AVX-512 path — 8-wide double SIMD
// Ported from FlexAIDdS ShannonThermoStack vectorized histogram
// =============================================================================

#ifdef SHANNON_HAS_AVX512

static double shannon_entropy_avx512(const double* probs, size_t n) {
    __m512d acc = _mm512_setzero_pd();
    __m512d zero = _mm512_setzero_pd();

    size_t i = 0;
    const size_t vec_end = n - (n % 8);

    for (; i < vec_end; i += 8) {
        __m512d p = _mm512_loadu_pd(probs + i);

        // Mask out zero probabilities
        __mmask8 mask = _mm512_cmp_pd_mask(p, zero, _CMP_GT_OQ);

        // Compute log2(p) per lane (scalar fallback — portable, no SVML)
        alignas(64) double p_arr[8];
        alignas(64) double log2_arr[8];
        _mm512_store_pd(p_arr, p);

        for (int k = 0; k < 8; ++k) {
            log2_arr[k] = (p_arr[k] > 0.0) ? std::log2(p_arr[k]) : 0.0;
        }
        __m512d log2_p = _mm512_load_pd(log2_arr);

        // p * log2(p), masked
        __m512d plog = _mm512_mul_pd(p, log2_p);
        plog = _mm512_maskz_mov_pd(mask, plog);

        acc = _mm512_sub_pd(acc, plog);
    }

    // Horizontal sum
    double H = _mm512_reduce_add_pd(acc);

    // Tail elements
    for (; i < n; ++i) {
        if (probs[i] > 0.0) {
            H -= probs[i] * std::log2(probs[i]);
        }
    }
    return H;
}

#endif  // SHANNON_HAS_AVX512

// =============================================================================
// Runtime dispatch — function pointer resolved once at init
// Pattern ported from FlexAIDdS resolve_entropy_impl()
// =============================================================================

namespace {

using entropy_fn_t = double(*)(const double*, size_t);

// __builtin_cpu_supports is available on GCC and non-Apple Clang on x86.
// Apple Clang does not support it. On ARM, none of the SHANNON_HAS_AVX*
// macros are defined, so these blocks are compiled out entirely.
#if defined(__GNUC__) && !defined(__apple_build_version__) && (defined(__x86_64__) || defined(__i386__))
#define SHANNON_CAN_CPUID 1
#endif

entropy_fn_t resolve_entropy_impl() {
#if defined(SHANNON_HAS_AVX512) && defined(SHANNON_CAN_CPUID)
    if (__builtin_cpu_supports("avx512f")) return shannon_entropy_avx512;
#endif

#if defined(SHANNON_HAS_AVX2) && defined(SHANNON_CAN_CPUID)
    if (__builtin_cpu_supports("avx2")) return shannon_entropy_avx2;
#endif

    // If compiled with AVX flags but no CPUID (e.g., Apple Clang x86),
    // use the SIMD path directly since the compiler already verified support.
#if defined(SHANNON_HAS_AVX512) && !defined(SHANNON_CAN_CPUID)
    return shannon_entropy_avx512;
#elif defined(SHANNON_HAS_AVX2) && !defined(SHANNON_CAN_CPUID)
    return shannon_entropy_avx2;
#endif

    return shannon_entropy_scalar;
}

entropy_fn_t g_entropy_impl = resolve_entropy_impl();

const char* resolve_backend_name() {
#if defined(SHANNON_HAS_AVX512) && defined(SHANNON_CAN_CPUID)
    if (__builtin_cpu_supports("avx512f")) return "avx512";
#elif defined(SHANNON_HAS_AVX512)
    return "avx512";
#endif
#if defined(SHANNON_HAS_AVX2) && defined(SHANNON_CAN_CPUID)
    if (__builtin_cpu_supports("avx2")) return "avx2";
#elif defined(SHANNON_HAS_AVX2) && !defined(SHANNON_HAS_AVX512)
    return "avx2";
#endif
#ifdef SHANNON_HAS_OPENMP
    return "openmp";
#endif
    return "scalar";
}

const char* g_backend_name = resolve_backend_name();

}  // anonymous namespace

// =============================================================================
// Public API: shannon_entropy
// =============================================================================

double shannon_entropy(const double* probs, size_t n) {
    if (n == 0) return 0.0;
    return g_entropy_impl(probs, n);
}

double shannon_entropy(std::span<const double> probs) {
    return shannon_entropy(probs.data(), probs.size());
}

// =============================================================================
// Public API: shannon_entropy_from_logits
//
// Fused log-sum-exp softmax + entropy — no intermediate probability allocation.
// Ported from FlexAIDdS StatMechEngine log-sum-exp:
//   w_i = ln(n_i) - beta * E_i
//   log_Z = max_w + log(sum(exp(w_i - max_w)))
//
// For LLM logits:
//   log_Z = max_logit + log(sum(exp(logit_i - max_logit)))
//   H = log2(e) * (log_Z - (1/Z) * sum(logit_i * exp(logit_i - max_logit)))
// =============================================================================

double shannon_entropy_from_logits(const double* logits, size_t n) {
    if (n == 0) return 0.0;
    if (n == 1) return 0.0;

    // Step 1: Find max logit for numerical stability
    double max_logit = logits[0];
#ifdef SHANNON_HAS_OPENMP
    if (n > 10000) {
        #pragma omp parallel for reduction(max:max_logit)
        for (size_t i = 1; i < n; ++i) {
            if (logits[i] > max_logit) max_logit = logits[i];
        }
    } else
#endif
    {
        for (size_t i = 1; i < n; ++i) {
            if (logits[i] > max_logit) max_logit = logits[i];
        }
    }

    // Step 2: Compute sum(exp(logit_i - max)) and sum(logit_i * exp(logit_i - max))
    // Single fused pass — the key insight from FlexAIDdS StatMechEngine
    double sum_exp = 0.0;
    double sum_x_exp = 0.0;

#ifdef SHANNON_HAS_OPENMP
    if (n > 10000) {
        #pragma omp parallel for simd reduction(+:sum_exp,sum_x_exp)
        for (size_t i = 0; i < n; ++i) {
            double shifted = logits[i] - max_logit;
            double e = std::exp(shifted);
            sum_exp += e;
            sum_x_exp += logits[i] * e;
        }
    } else
#endif
    {
        for (size_t i = 0; i < n; ++i) {
            double shifted = logits[i] - max_logit;
            double e = std::exp(shifted);
            sum_exp += e;
            sum_x_exp += logits[i] * e;
        }
    }

    // Step 3: Compute entropy
    // log_Z = max_logit + log(sum_exp)
    // H = log2(e) * (log_Z - sum_x_exp / sum_exp)
    //   = log2(e) * (max_logit + log(sum_exp) - sum_x_exp / sum_exp)
    double log_Z = max_logit + std::log(sum_exp);
    double mean_logit = sum_x_exp / sum_exp;
    double H = std::numbers::log2e * (log_Z - mean_logit);

    return std::max(H, 0.0);  // Clamp to non-negative (rounding errors)
}

double shannon_entropy_from_logits(std::span<const double> logits) {
    return shannon_entropy_from_logits(logits.data(), logits.size());
}

// =============================================================================
// Public API: compute_entropy (with collapse detection)
// =============================================================================

EntropyResult compute_entropy(const double* probs, size_t n,
                               double collapse_threshold) {
    double H = shannon_entropy(probs, n);
    double H_max = (n > 1) ? std::log2(static_cast<double>(n)) : 1.0;
    double H_norm = H / H_max;
    return EntropyResult{H, H_norm, H_norm < collapse_threshold};
}

EntropyResult compute_entropy_from_logits(const double* logits, size_t n,
                                           double collapse_threshold) {
    double H = shannon_entropy_from_logits(logits, n);
    double H_max = (n > 1) ? std::log2(static_cast<double>(n)) : 1.0;
    double H_norm = H / H_max;
    return EntropyResult{H, H_norm, H_norm < collapse_threshold};
}

// =============================================================================
// SlidingWindowEntropy
// =============================================================================

SlidingWindowEntropy::SlidingWindowEntropy(size_t window_size,
                                             double collapse_threshold)
    : window_size_(window_size)
    , collapse_threshold_(collapse_threshold)
    , regression_denom_(0.0)
{
    precompute_regression_denom();
}

void SlidingWindowEntropy::precompute_regression_denom() {
    // Denominator for linear regression slope:
    // denom = n * sum(i^2) - (sum(i))^2
    // where i = 0, 1, ..., n-1
    size_t n = window_size_;
    double sum_i = static_cast<double>(n * (n - 1)) / 2.0;
    double sum_i2 = static_cast<double>(n * (n - 1) * (2 * n - 1)) / 6.0;
    regression_denom_ = static_cast<double>(n) * sum_i2 - sum_i * sum_i;
}

void SlidingWindowEntropy::push(double entropy_value) {
    trace_.push_back(entropy_value);
    buffer_.push_back(entropy_value);

    if (buffer_.size() > window_size_) {
        buffer_.pop_front();
    }

    // Check for collapse and fire callback
    if (on_collapse_ && buffer_.size() == window_size_ && is_collapsed()) {
        CollapseEvent event{
            trace_.size() - 1,
            entropy_value,
            delta_h(),
            collapse_score()
        };
        on_collapse_(event);
    }
}

void SlidingWindowEntropy::push_logits(const double* logits, size_t n) {
    push(shannon_entropy_from_logits(logits, n));
}

double SlidingWindowEntropy::current_entropy() const {
    if (buffer_.empty()) return 0.0;
    return buffer_.back();
}

double SlidingWindowEntropy::mean_entropy() const {
    if (buffer_.empty()) return 0.0;
    double sum = 0.0;
    for (double v : buffer_) sum += v;
    return sum / static_cast<double>(buffer_.size());
}

double SlidingWindowEntropy::delta_h() const {
    if (buffer_.size() < 2) return 0.0;

    size_t n = buffer_.size();
    double sum_i = 0.0;
    double sum_h = 0.0;
    double sum_ih = 0.0;
    double sum_i2 = 0.0;

    for (size_t i = 0; i < n; ++i) {
        double di = static_cast<double>(i);
        double hi = buffer_[i];
        sum_i  += di;
        sum_h  += hi;
        sum_ih += di * hi;
        sum_i2 += di * di;
    }

    double dn = static_cast<double>(n);
    double denom = dn * sum_i2 - sum_i * sum_i;
    if (std::abs(denom) < 1e-15) return 0.0;

    return (dn * sum_ih - sum_i * sum_h) / denom;
}

bool SlidingWindowEntropy::is_collapsed() const {
    return delta_h() < collapse_threshold_;
}

double SlidingWindowEntropy::collapse_score() const {
    if (std::abs(collapse_threshold_) < 1e-15) return 0.0;
    return std::abs(delta_h() / collapse_threshold_);
}

void SlidingWindowEntropy::reset() {
    buffer_.clear();
    trace_.clear();
}

void SlidingWindowEntropy::set_on_collapse(
    std::function<void(const CollapseEvent&)> callback
) {
    on_collapse_ = std::move(callback);
}

// =============================================================================
// Hardware info
// =============================================================================

HardwareInfo get_hardware_info() {
    HardwareInfo info{};

#ifdef SHANNON_HAS_AVX512
#ifdef SHANNON_CAN_CPUID
    info.has_avx512 = __builtin_cpu_supports("avx512f");
#else
    info.has_avx512 = true;  // compiled with AVX-512 flags
#endif
#endif

#ifdef SHANNON_HAS_AVX2
#ifdef SHANNON_CAN_CPUID
    info.has_avx2 = __builtin_cpu_supports("avx2");
#else
    info.has_avx2 = true;  // compiled with AVX2 flags
#endif
#endif

#ifdef SHANNON_HAS_OPENMP
    info.has_openmp = true;
#endif

#ifdef SHANNON_HAS_CUDA
    info.has_cuda = true;
#endif

#ifdef SHANNON_HAS_METAL
    info.has_metal = true;
#endif

    info.active_backend = g_backend_name;
    return info;
}

}  // namespace shannon
