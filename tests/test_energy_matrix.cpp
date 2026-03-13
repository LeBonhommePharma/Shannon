// =============================================================================
// Shannon — GoogleTest Suite for 256x256 ShannonEnergyMatrix
//
// Tests: singleton, symmetry, known values, nonzero count.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <gtest/gtest.h>
#include "energy_matrix.h"
#include <cmath>

TEST(EnergyMatrix, Singleton) {
    const auto& m1 = shannon::ShannonEnergyMatrix::instance();
    const auto& m2 = shannon::ShannonEnergyMatrix::instance();
    EXPECT_EQ(&m1, &m2);
}

TEST(EnergyMatrix, Dimensions) {
    EXPECT_EQ(shannon::ShannonEnergyMatrix::DIM, 256u);
    EXPECT_EQ(shannon::ShannonEnergyMatrix::TOTAL_PARAMS, 65536u);
}

TEST(EnergyMatrix, Symmetry) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    for (int i = 0; i < 256; i += 7) {
        for (int j = i; j < 256; j += 11) {
            EXPECT_DOUBLE_EQ(m.energy(i, j), m.energy(j, i))
                << "Asymmetry at (" << i << "," << j << ")";
        }
    }
}

TEST(EnergyMatrix, DiagonalFinite) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    for (int i = 0; i < 256; ++i) {
        double e = m.energy(i, i);
        EXPECT_FALSE(std::isnan(e)) << "NaN at diagonal (" << i << "," << i << ")";
        EXPECT_FALSE(std::isinf(e)) << "Inf at diagonal (" << i << "," << i << ")";
    }
}

TEST(EnergyMatrix, NonzeroParameters) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    // The matrix should have a large number of non-zero entries
    size_t nz = m.nonzero_count();
    EXPECT_GT(nz, 60000u);  // Most entries should be non-zero
}

TEST(EnergyMatrix, InteractionScoreConsistency) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    EXPECT_DOUBLE_EQ(m.interaction_score(10, 20), m.energy(10, 20));
}

TEST(EnergyMatrix, WeightedEntropy) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();

    // Uniform probabilities
    constexpr size_t n = 10;
    double probs[n];
    for (size_t i = 0; i < n; ++i) probs[i] = 1.0 / n;

    uint8_t context[] = {0, 1, 2};
    double H_w = m.weighted_entropy(probs, n, context, 3);
    EXPECT_FALSE(std::isnan(H_w));
    EXPECT_GE(H_w, 0.0);
}

TEST(EnergyMatrix, WeightedEntropyEmpty) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    double H = m.weighted_entropy(nullptr, 0, nullptr, 0);
    EXPECT_NEAR(H, 0.0, 1e-15);
}
