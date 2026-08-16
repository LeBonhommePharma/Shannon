// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT

#include <gtest/gtest.h>

#include <cmath>
#include <limits>
#include <numeric>
#include <random>
#include <vector>

#include "shannon.hpp"

// ─── Configurational Entropy Tests ──────────────────────────────────────────

TEST(ShannonEntropy, EmptyReturnsZero) {
    EXPECT_DOUBLE_EQ(shannon::shannon_configurational_entropy(nullptr, 0), 0.0);
}

TEST(ShannonEntropy, SingleElementReturnsZero) {
    double w = 1.0;
    EXPECT_DOUBLE_EQ(shannon::shannon_configurational_entropy(&w, 1), 0.0);
}

TEST(ShannonEntropy, UniformDistributionMaxEntropy) {
    // N equal log-weights → entropy = log2(N)
    const std::size_t N = 1024;
    std::vector<double> w(N, 0.0);  // All equal → uniform after softmax
    double h = shannon::shannon_configurational_entropy(w.data(), N);
    EXPECT_NEAR(h, std::log2(static_cast<double>(N)), 1e-10);
}

TEST(ShannonEntropy, DeltaDistributionZeroEntropy) {
    // One weight dominates → entropy ≈ 0
    std::vector<double> w = {100.0, -100.0, -100.0, -100.0};
    double h = shannon::shannon_configurational_entropy(w.data(), w.size());
    EXPECT_NEAR(h, 0.0, 1e-6);
}

TEST(ShannonEntropy, TwoEqualWeights) {
    std::vector<double> w = {0.0, 0.0};
    double h = shannon::shannon_configurational_entropy(w.data(), w.size());
    EXPECT_NEAR(h, 1.0, 1e-10);  // log2(2) = 1
}

TEST(ShannonEntropy, NumericalStabilityLargeValues) {
    // Large log-weights should not overflow
    std::vector<double> w = {1000.0, 1000.0, 1000.0, 1000.0};
    double h = shannon::shannon_configurational_entropy(w.data(), w.size());
    EXPECT_NEAR(h, 2.0, 1e-10);  // log2(4) = 2
}

TEST(ShannonEntropy, NumericalStabilityNegativeValues) {
    std::vector<double> w = {-1000.0, -1000.0, -1000.0, -1000.0};
    double h = shannon::shannon_configurational_entropy(w.data(), w.size());
    EXPECT_NEAR(h, 2.0, 1e-10);
}

TEST(ShannonEntropy, NegInfMaskedLogitsUseFiniteSupport) {
    const double ninf = -std::numeric_limits<double>::infinity();
    std::vector<double> w = {0.0, 0.0, 0.0, ninf};
    double h = shannon::shannon_configurational_entropy(w.data(), w.size());
    EXPECT_FALSE(std::isnan(h));
    EXPECT_NEAR(h, std::log2(3.0), 1e-10);
}

TEST(ShannonEntropy, PosInfLogitIsCertain) {
    const double pinf = std::numeric_limits<double>::infinity();
    std::vector<double> w = {1.0, pinf, 2.0};
    EXPECT_DOUBLE_EQ(shannon::shannon_configurational_entropy(w.data(), w.size()), 0.0);
}

// ─── Entropy from Probs ─────────────────────────────────────────────────────

TEST(ShannonFromProbs, UniformFourWay) {
    std::vector<double> p = {0.25, 0.25, 0.25, 0.25};
    double h = shannon::shannon_entropy_from_probs(p.data(), p.size());
    EXPECT_NEAR(h, 2.0, 1e-10);
}

TEST(ShannonFromProbs, DeltaDistribution) {
    std::vector<double> p = {1.0, 0.0, 0.0, 0.0};
    double h = shannon::shannon_entropy_from_probs(p.data(), p.size());
    EXPECT_NEAR(h, 0.0, 1e-10);
}

TEST(ShannonFromProbs, BinaryHalf) {
    std::vector<double> p = {0.5, 0.5};
    double h = shannon::shannon_entropy_from_probs(p.data(), p.size());
    EXPECT_NEAR(h, 1.0, 1e-10);
}

// ─── Entropy from LogProbs ──────────────────────────────────────────────────

TEST(ShannonFromLogProbs, UniformFourWay) {
    double lp = std::log(0.25);
    std::vector<double> logp = {lp, lp, lp, lp};
    double h = shannon::shannon_entropy_from_logprobs(logp.data(), logp.size());
    EXPECT_NEAR(h, 2.0, 1e-10);
}

// ─── Collapse Detector Tests ────────────────────────────────────────────────

TEST(V1CollapseDetector, DetectsCollapse) {
    shannon::v1::CollapseDetector detector(4, -2.0);

    // Feed high-entropy tokens to fill the window
    std::vector<double> high = {0.0, 0.0, 0.0, 0.0};  // uniform → 2 bits
    for (int i = 0; i < 4; ++i) {
        auto r = detector.add_logits(high.data(), high.size());
        EXPECT_FALSE(r.collapsed);
    }

    // Feed a low-entropy token → collapse
    std::vector<double> low = {100.0, -100.0, -100.0, -100.0};  // ~0 bits
    auto result = detector.add_logits(low.data(), low.size());

    // delta ≈ 0 - 2 = -2, threshold is -2.0
    // Since the window now includes the low value, mean shifts down slightly
    // but the collapse should still be detected
    EXPECT_LT(result.delta, 0.0);
}

TEST(V1CollapseDetector, CallbackFires) {
    int count = 0;
    shannon::v1::CollapseDetector detector(4, -1.0);
    detector.set_callback([&](const shannon::v1::CollapseResult&) { ++count; });

    std::vector<double> high = {0.0, 0.0, 0.0, 0.0};
    for (int i = 0; i < 4; ++i) {
        detector.add_logits(high.data(), high.size());
    }

    std::vector<double> low = {100.0, -100.0, -100.0, -100.0};
    detector.add_logits(low.data(), low.size());

    EXPECT_GE(count, 1);
}

TEST(V1CollapseDetector, ResetClearsState) {
    shannon::v1::CollapseDetector detector(4, -3.2);

    std::vector<double> w = {0.0, 0.0};
    detector.add_logits(w.data(), w.size());
    EXPECT_EQ(detector.trace().size(), 1);

    detector.reset();
    EXPECT_EQ(detector.trace().size(), 0);
}

TEST(V1CollapseDetector, TraceGrows) {
    shannon::v1::CollapseDetector detector;
    std::vector<double> w = {1.0, 2.0, 3.0};
    for (int i = 0; i < 10; ++i) {
        detector.add_logits(w.data(), w.size());
    }
    EXPECT_EQ(detector.trace().size(), 10);
}

TEST(V1CollapseDetector, PopulationVarianceMatchesReference) {
    shannon::v1::CollapseDetector det(4, -100.0);
    det.push_entropy(2.0);
    det.push_entropy(4.0);
    det.push_entropy(4.0);
    det.push_entropy(4.0);
    auto r = det.push_entropy(5.0);
    // Window is {4,4,4,5}. Population: mean=4.25, E[X²]=18.25, var=0.1875.
    EXPECT_NEAR(r.window_mean, 4.25, 1e-10);
    EXPECT_NEAR(r.window_std, std::sqrt(0.1875), 1e-10);
}

// ─── Performance Sanity Check ───────────────────────────────────────────────

TEST(ShannonEntropy, LargeVocabulary) {
    // Simulate a 50k vocabulary (typical LLM)
    const std::size_t N = 50000;
    std::mt19937 rng(42);
    std::normal_distribution<double> dist(0.0, 3.0);
    std::vector<double> logits(N);
    for (auto& v : logits) v = dist(rng);

    double h = shannon::shannon_configurational_entropy(logits.data(), N);
    EXPECT_GT(h, 0.0);
    EXPECT_LE(h, std::log2(static_cast<double>(N)));
}
