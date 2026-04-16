// =============================================================================
// Shannon — GoogleTest Suite for Core Entropy Kernels
//
// Tests: analytical values, numerical stability, SIMD consistency,
//        SlidingWindowEntropy, edge cases, large vocabularies.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <gtest/gtest.h>
#include "shannon.h"
#include <cmath>
#include <numeric>
#include <random>
#include <vector>

// =============================================================================
// shannon_entropy — known analytical values
// =============================================================================

TEST(ShannonEntropy, UniformDistribution) {
    // Uniform: H = log2(n)
    for (size_t n : {2, 4, 8, 16, 256, 1000}) {
        std::vector<double> probs(n, 1.0 / static_cast<double>(n));
        double H = shannon::shannon_entropy(probs.data(), probs.size());
        double expected = std::log2(static_cast<double>(n));
        EXPECT_NEAR(H, expected, 1e-10)
            << "Failed for n=" << n;
    }
}

TEST(ShannonEntropy, DeltaDistribution) {
    // Single dominant: H = 0
    for (size_t n : {1, 2, 10, 100}) {
        std::vector<double> probs(n, 0.0);
        probs[0] = 1.0;
        double H = shannon::shannon_entropy(probs.data(), probs.size());
        EXPECT_NEAR(H, 0.0, 1e-12)
            << "Failed for n=" << n;
    }
}

TEST(ShannonEntropy, BinaryFairCoin) {
    std::vector<double> probs = {0.5, 0.5};
    double H = shannon::shannon_entropy(probs.data(), probs.size());
    EXPECT_NEAR(H, 1.0, 1e-12);
}

TEST(ShannonEntropy, QuarterDistribution) {
    std::vector<double> probs = {0.25, 0.25, 0.25, 0.25};
    double H = shannon::shannon_entropy(probs.data(), probs.size());
    EXPECT_NEAR(H, 2.0, 1e-12);
}

TEST(ShannonEntropy, AsymmetricBinary) {
    // H(0.9, 0.1) = -0.9*log2(0.9) - 0.1*log2(0.1)
    std::vector<double> probs = {0.9, 0.1};
    double H = shannon::shannon_entropy(probs.data(), probs.size());
    double expected = -0.9 * std::log2(0.9) - 0.1 * std::log2(0.1);
    EXPECT_NEAR(H, expected, 1e-12);
}

// =============================================================================
// shannon_entropy_from_logits — consistency with softmax
// =============================================================================

TEST(ShannonEntropyFromLogits, ConsistentWithSoftmax) {
    // Verify: entropy_from_logits(logits) == entropy(softmax(logits))
    std::vector<double> logits = {1.0, 2.0, 3.0, 4.0, 5.0};

    // Manual softmax
    double max_l = *std::max_element(logits.begin(), logits.end());
    double sum_exp = 0.0;
    std::vector<double> probs(logits.size());
    for (size_t i = 0; i < logits.size(); ++i) {
        probs[i] = std::exp(logits[i] - max_l);
        sum_exp += probs[i];
    }
    for (auto& p : probs) p /= sum_exp;

    double H_from_probs = shannon::shannon_entropy(probs.data(), probs.size());
    double H_from_logits = shannon::shannon_entropy_from_logits(logits.data(), logits.size());

    EXPECT_NEAR(H_from_probs, H_from_logits, 1e-10);
}

TEST(ShannonEntropyFromLogits, UniformLogits) {
    // All equal logits -> uniform distribution -> H = log2(n)
    size_t n = 100;
    std::vector<double> logits(n, 5.0);
    double H = shannon::shannon_entropy_from_logits(logits.data(), logits.size());
    EXPECT_NEAR(H, std::log2(static_cast<double>(n)), 1e-10);
}

TEST(ShannonEntropyFromLogits, SingleLogit) {
    std::vector<double> logits = {42.0};
    double H = shannon::shannon_entropy_from_logits(logits.data(), logits.size());
    EXPECT_NEAR(H, 0.0, 1e-12);
}

// =============================================================================
// Numerical stability — extreme logits
// =============================================================================

TEST(NumericalStability, LargeLogits) {
    // Logits with magnitude > 500 would overflow naive softmax
    std::vector<double> logits = {500.0, 501.0, 499.0, 500.5};
    double H = shannon::shannon_entropy_from_logits(logits.data(), logits.size());
    EXPECT_FALSE(std::isnan(H));
    EXPECT_FALSE(std::isinf(H));
    EXPECT_GE(H, 0.0);
}

TEST(NumericalStability, VeryNegativeLogits) {
    std::vector<double> logits = {-500.0, -501.0, -499.0, -500.5};
    double H = shannon::shannon_entropy_from_logits(logits.data(), logits.size());
    EXPECT_FALSE(std::isnan(H));
    EXPECT_FALSE(std::isinf(H));
    EXPECT_GE(H, 0.0);
}

TEST(NumericalStability, MixedExtremeLogits) {
    // One dominant, rest very negative
    std::vector<double> logits = {100.0, -100.0, -200.0, -300.0};
    double H = shannon::shannon_entropy_from_logits(logits.data(), logits.size());
    EXPECT_FALSE(std::isnan(H));
    EXPECT_NEAR(H, 0.0, 0.01);  // Nearly delta distribution
}

// =============================================================================
// Large vocabulary (LLM-scale)
// =============================================================================

TEST(LargeVocab, Vocab32k) {
    size_t n = 32000;
    std::vector<double> probs(n, 1.0 / static_cast<double>(n));
    double H = shannon::shannon_entropy(probs.data(), probs.size());
    EXPECT_NEAR(H, std::log2(static_cast<double>(n)), 1e-8);
}

TEST(LargeVocab, Vocab128k) {
    size_t n = 128000;
    std::vector<double> logits(n);
    std::mt19937 rng(42);
    std::normal_distribution<double> dist(0.0, 1.0);
    for (auto& l : logits) l = dist(rng);

    double H = shannon::shannon_entropy_from_logits(logits.data(), logits.size());
    EXPECT_FALSE(std::isnan(H));
    EXPECT_FALSE(std::isinf(H));
    EXPECT_GT(H, 0.0);
}

// =============================================================================
// Edge cases
// =============================================================================

TEST(EdgeCases, EmptyInput) {
    double H = shannon::shannon_entropy(nullptr, 0);
    EXPECT_NEAR(H, 0.0, 1e-15);
}

TEST(EdgeCases, SingleElement) {
    double p = 1.0;
    double H = shannon::shannon_entropy(&p, 1);
    EXPECT_NEAR(H, 0.0, 1e-15);
}

TEST(EdgeCases, EmptyLogits) {
    double H = shannon::shannon_entropy_from_logits(nullptr, 0);
    EXPECT_NEAR(H, 0.0, 1e-15);
}

// =============================================================================
// compute_entropy — EntropyResult
// =============================================================================

TEST(ComputeEntropy, NormalizationAndCollapse) {
    std::vector<double> probs = {0.99, 0.01};
    auto result = shannon::compute_entropy(probs.data(), probs.size(), 0.5);
    EXPECT_NEAR(result.H_normalized, result.H / std::log2(2.0), 1e-10);
    EXPECT_TRUE(result.collapsed);  // Very low entropy

    std::vector<double> uniform = {0.5, 0.5};
    auto result2 = shannon::compute_entropy(uniform.data(), uniform.size(), 0.5);
    EXPECT_FALSE(result2.collapsed);
}

// =============================================================================
// SlidingWindowEntropy
// =============================================================================

TEST(SlidingWindow, ConstantEntropy) {
    shannon::SlidingWindowEntropy window(8, -3.2);
    for (int i = 0; i < 10; ++i) {
        window.push(5.0);
    }
    EXPECT_NEAR(window.mean_entropy(), 5.0, 1e-12);
    EXPECT_NEAR(window.delta_h(), 0.0, 1e-12);
    EXPECT_FALSE(window.is_collapsed());
}

TEST(SlidingWindow, LinearDecrease) {
    shannon::SlidingWindowEntropy window(8, -3.2);
    // Push linearly decreasing: 8.0, 7.0, 6.0, ..., 1.0
    for (int i = 0; i < 8; ++i) {
        window.push(8.0 - static_cast<double>(i));
    }
    // Slope should be -1.0
    EXPECT_NEAR(window.delta_h(), -1.0, 1e-10);
    EXPECT_FALSE(window.is_collapsed());  // -1.0 > -3.2
}

TEST(SlidingWindow, SteepCollapse) {
    shannon::SlidingWindowEntropy window(4, -3.2);
    // Steep drop: 10.0, 6.0, 2.0, -2.0 (slope ~ -4.0)
    window.push(10.0);
    window.push(6.0);
    window.push(2.0);
    window.push(-2.0);
    EXPECT_NEAR(window.delta_h(), -4.0, 1e-10);
    EXPECT_TRUE(window.is_collapsed());   // -4.0 < -3.2
    EXPECT_GT(window.collapse_score(), 1.0);
}

TEST(SlidingWindow, Reset) {
    shannon::SlidingWindowEntropy window(4, -3.2);
    window.push(1.0);
    window.push(2.0);
    window.push(3.0);
    EXPECT_EQ(window.token_count(), 3);

    window.reset();
    EXPECT_EQ(window.token_count(), 0);
    EXPECT_NEAR(window.current_entropy(), 0.0, 1e-15);
}

TEST(SlidingWindow, CollapseCallback) {
    int callback_count = 0;
    shannon::CollapseEvent last_event{};

    shannon::SlidingWindowEntropy window(3, -2.0);
    window.set_on_collapse([&](const shannon::CollapseEvent& event) {
        ++callback_count;
        last_event = event;
    });

    // No collapse
    window.push(5.0);
    window.push(5.0);
    window.push(5.0);
    EXPECT_EQ(callback_count, 0);

    window.reset();

    // Force collapse: steep descent
    window.push(10.0);
    window.push(5.0);
    window.push(0.0);
    EXPECT_GE(callback_count, 1);
    EXPECT_NEAR(last_event.entropy, 0.0, 1e-12);
}

// =============================================================================
// Hardware info
// =============================================================================

TEST(HardwareInfo, NonEmpty) {
    auto info = shannon::get_hardware_info();
    EXPECT_FALSE(info.active_backend.empty());
}
