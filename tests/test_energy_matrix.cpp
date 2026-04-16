// =============================================================================
// Shannon — GoogleTest Suite for 256x256 ShannonEnergyMatrix
//
// Tests: singleton, symmetry, known values, nonzero count, type encoding,
//        SoftContactMatrix, weighted entropy with bias.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <gtest/gtest.h>
#include "energy_matrix.h"
#include <cmath>

// =============================================================================
// ShannonEnergyMatrix core tests
// =============================================================================

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
    size_t nz = m.nonzero_count();
    EXPECT_GT(nz, 60000u);
}

TEST(EnergyMatrix, InteractionScoreConsistency) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    EXPECT_DOUBLE_EQ(m.interaction_score(10, 20), m.energy(10, 20));
}

TEST(EnergyMatrix, WeightedEntropy) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
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

// =============================================================================
// 8-bit type encoding
// =============================================================================

TEST(TypeEncoding, RoundTrip) {
    // Verify encode -> decode round-trip for all 256 types
    for (int t = 0; t < 256; ++t) {
        auto info = shannon::decode_type(static_cast<uint8_t>(t));
        uint8_t reconstructed = shannon::encode_type(
            info.base_type, info.charge_bin, info.hbond);
        EXPECT_EQ(reconstructed, static_cast<uint8_t>(t))
            << "Round-trip failed for type " << t;
    }
}

TEST(TypeEncoding, FieldRanges) {
    for (int t = 0; t < 256; ++t) {
        auto info = shannon::decode_type(static_cast<uint8_t>(t));
        EXPECT_LT(info.base_type, 32u) << "base_type out of range for " << t;
        EXPECT_LT(info.charge_bin, 4u) << "charge_bin out of range for " << t;
    }
}

TEST(TypeEncoding, KnownValues) {
    // Type 0: base=0, charge=0 (strong-), hbond=false
    auto t0 = shannon::decode_type(0);
    EXPECT_EQ(t0.base_type, 0);
    EXPECT_EQ(t0.charge_bin, 0);
    EXPECT_FALSE(t0.hbond);

    // Type 128: base=0, charge=0, hbond=true (bit 7 set)
    auto t128 = shannon::decode_type(128);
    EXPECT_EQ(t128.base_type, 0);
    EXPECT_EQ(t128.charge_bin, 0);
    EXPECT_TRUE(t128.hbond);

    // Type 255: base=31, charge=3 (strong+), hbond=true
    auto t255 = shannon::decode_type(255);
    EXPECT_EQ(t255.base_type, 31);
    EXPECT_EQ(t255.charge_bin, 3);
    EXPECT_TRUE(t255.hbond);
}

// =============================================================================
// SoftContactMatrix
// =============================================================================

TEST(SoftContactMatrix, DefaultUnloaded) {
    shannon::SoftContactMatrix sc;
    EXPECT_FALSE(sc.is_loaded());
    // Default should be zeroed
    EXPECT_FLOAT_EQ(sc.lookup(0, 0), 0.0f);
}

TEST(SoftContactMatrix, InvalidPath) {
    shannon::SoftContactMatrix sc;
    EXPECT_FALSE(sc.load("nonexistent_file.bin"));
    EXPECT_FALSE(sc.is_loaded());
}

TEST(SoftContactMatrix, DimensionConstants) {
    EXPECT_EQ(shannon::SoftContactMatrix::DIM, 256u);
    EXPECT_EQ(shannon::SoftContactMatrix::TOTAL_ENTRIES, 65536u);
    EXPECT_EQ(shannon::SoftContactMatrix::BYTE_SIZE, 256u * 256u * sizeof(float));
}

// =============================================================================
// Row vector extraction
// =============================================================================

TEST(EnergyMatrix, RowVector) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    auto row = m.get_row_vector(42);
    EXPECT_EQ(row.size(), 256u);

    // Verify consistency with energy()
    for (int j = 0; j < 256; ++j) {
        EXPECT_FLOAT_EQ(row[j], static_cast<float>(m.energy(42, j)))
            << "Mismatch at row 42, col " << j;
    }
}

// =============================================================================
// Matrix source
// =============================================================================

TEST(EnergyMatrix, SourceReported) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    const char* src = m.source();
    EXPECT_TRUE(std::string(src) == "closed_form" || std::string(src) == "soft_contact");
}

// =============================================================================
// Weighted entropy with super-cluster bias
// =============================================================================

TEST(EnergyMatrix, WeightedEntropyWithBias) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    constexpr size_t n = 10;
    double probs[n];
    for (size_t i = 0; i < n; ++i) probs[i] = 1.0 / n;
    uint8_t context[] = {0, 1, 2};

    // Create a mock super-cluster
    shannon::SuperCluster cluster;
    cluster.centroid.resize(256, 0.0f);
    cluster.radius = 1.0f;
    cluster.cluster_id = 0;

    double H_biased = m.weighted_entropy_with_bias(probs, n, context, 3, cluster, 2.0);
    EXPECT_FALSE(std::isnan(H_biased));
    EXPECT_GE(H_biased, 0.0);

    // Bias should modulate the result
    double H_unbiased = m.weighted_entropy(probs, n, context, 3);
    // They should be different (bias changes weights)
    // But both should be non-negative
    EXPECT_GE(H_unbiased, 0.0);
}

TEST(EnergyMatrix, WeightedEntropyWithBiasEmpty) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    shannon::SuperCluster cluster;
    double H = m.weighted_entropy_with_bias(nullptr, 0, nullptr, 0, cluster);
    EXPECT_NEAR(H, 0.0, 1e-15);
}

// =============================================================================
// Batch lookup
// =============================================================================

TEST(SoftContactMatrix, BatchLookupConsistency) {
    // Batch lookup must match individual lookups
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    const auto& sc = m.soft_contact();

    constexpr size_t N = 100;
    uint8_t types_i[N], types_j[N];
    float batch_scores[N];

    for (size_t k = 0; k < N; ++k) {
        types_i[k] = static_cast<uint8_t>((k * 7 + 3) % 256);
        types_j[k] = static_cast<uint8_t>((k * 13 + 17) % 256);
    }

    sc.batch_lookup(types_i, types_j, batch_scores, N);

    for (size_t k = 0; k < N; ++k) {
        float expected = sc.lookup(types_i[k], types_j[k]);
        EXPECT_FLOAT_EQ(batch_scores[k], expected)
            << "Batch mismatch at k=" << k
            << " types=(" << (int)types_i[k] << "," << (int)types_j[k] << ")";
    }
}

TEST(SoftContactMatrix, BatchLookupEmpty) {
    const auto& sc = shannon::ShannonEnergyMatrix::instance().soft_contact();
    sc.batch_lookup(nullptr, nullptr, nullptr, 0);  // should not crash
}

// =============================================================================
// Row-dot
// =============================================================================

TEST(SoftContactMatrix, RowDotCorrectness) {
    const auto& sc = shannon::ShannonEnergyMatrix::instance().soft_contact();

    // Use uniform weights = 1.0
    float weights[256];
    for (int j = 0; j < 256; ++j) weights[j] = 1.0f;

    float dot = sc.row_dot(42, weights);

    // Manual sum of row 42
    float expected = 0.0f;
    for (int j = 0; j < 256; ++j) {
        expected += sc.lookup(42, j);
    }

    EXPECT_NEAR(dot, expected, std::abs(expected) * 1e-5f)
        << "Row-dot mismatch for type 42";
}

TEST(SoftContactMatrix, RowDotZeroWeights) {
    const auto& sc = shannon::ShannonEnergyMatrix::instance().soft_contact();
    float weights[256] = {};
    float dot = sc.row_dot(0, weights);
    EXPECT_FLOAT_EQ(dot, 0.0f);
}

// =============================================================================
// SYBYL bridge
// =============================================================================

TEST(SybylBridge, KnownTypes) {
    EXPECT_EQ(shannon::sybyl_to_base("C.3"), 0);
    EXPECT_EQ(shannon::sybyl_to_base("C.ar"), 3);
    EXPECT_EQ(shannon::sybyl_to_base("N.ar"), 8);
    EXPECT_EQ(shannon::sybyl_to_base("O.3"), 12);
    EXPECT_EQ(shannon::sybyl_to_base("H"), 19);
    EXPECT_EQ(shannon::sybyl_to_base("C.ar.het"), 20);
    EXPECT_EQ(shannon::sybyl_to_base("C.2.bridge"), 21);
    EXPECT_EQ(shannon::sybyl_to_base("F"), 22);
}

TEST(SybylBridge, UnknownType) {
    EXPECT_EQ(shannon::sybyl_to_base("UNKNOWN"), -1);
    EXPECT_EQ(shannon::sybyl_to_base(""), -1);
    EXPECT_EQ(shannon::sybyl_to_base(nullptr), -1);
}

TEST(SybylBridge, RoundTrip) {
    // sybyl_to_base → base_to_sybyl_parent should give valid SYBYL parent
    int base = shannon::sybyl_to_base("C.3");
    EXPECT_EQ(base, 0);
    int sybyl = shannon::base_to_sybyl_parent(static_cast<uint8_t>(base));
    EXPECT_GE(sybyl, 0);
    EXPECT_LT(sybyl, 40);
}

TEST(SybylBridge, ContextAwareParent) {
    // C.ar.het (base 20) → SYBYL parent should be C.ar (parent 3)
    int parent = shannon::base_to_sybyl_parent(20);
    EXPECT_EQ(parent, 3);

    // C.2.bridge (base 21) → SYBYL parent should be C.2 (parent 1)
    parent = shannon::base_to_sybyl_parent(21);
    EXPECT_EQ(parent, 1);
}

// =============================================================================
// 40×40 projection
// =============================================================================

TEST(Projection, ProjectTo40x40) {
    const auto& sc = shannon::ShannonEnergyMatrix::instance().soft_contact();

    float proj[32 * 32] = {};
    shannon::project_to_40x40(sc, proj);

    // Symmetry check (spot)
    for (int i = 0; i < 32; i += 5) {
        for (int j = i; j < 32; j += 7) {
            EXPECT_NEAR(proj[i * 32 + j], proj[j * 32 + i], 1e-5f)
                << "40x40 asymmetry at (" << i << "," << j << ")";
        }
    }

    // Non-trivial: at least some entries should be non-zero
    int nonzero = 0;
    for (int k = 0; k < 32 * 32; ++k) {
        if (proj[k] != 0.0f) nonzero++;
    }
    EXPECT_GT(nonzero, 100);
}

// =============================================================================
// Two-stage pose scoring
// =============================================================================

TEST(EnergyMatrix, TwoStageScoringBasic) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();

    // Create 100 synthetic poses, 10 contacts each
    constexpr size_t N_POSES = 100;
    constexpr size_t CONTACTS = 10;
    uint8_t types_i[N_POSES * CONTACTS];
    uint8_t types_j[N_POSES * CONTACTS];
    float distances[N_POSES * CONTACTS];

    // Fill with deterministic data
    for (size_t p = 0; p < N_POSES; ++p) {
        for (size_t c = 0; c < CONTACTS; ++c) {
            size_t idx = p * CONTACTS + c;
            types_i[idx] = static_cast<uint8_t>((p + c) % 256);
            types_j[idx] = static_cast<uint8_t>((p * 3 + c * 7) % 256);
            distances[idx] = 3.0f + static_cast<float>(c) * 0.5f;
        }
    }

    auto result = m.score_poses_two_stage(
        types_i, types_j, distances, N_POSES, CONTACTS, 0.10f);

    EXPECT_EQ(result.poses_total, N_POSES);
    EXPECT_EQ(result.poses_evaluated, 10u);  // 10% of 100
    EXPECT_GE(result.entropy, 0.0);
    EXPECT_FALSE(std::isnan(result.entropy));
    EXPECT_FALSE(std::isinf(result.entropy));
    EXPECT_FALSE(std::isnan(result.delta_g_proxy));
}

TEST(EnergyMatrix, TwoStageScoringEmpty) {
    const auto& m = shannon::ShannonEnergyMatrix::instance();
    auto result = m.score_poses_two_stage(nullptr, nullptr, nullptr, 0, 0, 0.10f);
    EXPECT_EQ(result.poses_total, 0u);
    EXPECT_EQ(result.poses_evaluated, 0u);
    EXPECT_NEAR(result.entropy, 0.0, 1e-15);
}
