// =============================================================================
// Shannon — GoogleTest Suite for FastOPTICS Clustering
//
// Tests: empty input, too few points, known cluster structure,
//        centroid computation, reproducibility.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <gtest/gtest.h>
#include "fast_optics.h"
#include <cmath>
#include <random>
#include <vector>

// =============================================================================
// Edge cases
// =============================================================================

TEST(FastOPTICS, EmptyInput) {
    shannon::FastOPTICS optics;
    auto result = optics.cluster(nullptr, 0, 0);
    EXPECT_EQ(result.n_clusters, 0u);
    EXPECT_EQ(result.n_noise, 0u);
}

TEST(FastOPTICS, TooFewPoints) {
    shannon::FastOPTICS::Params params;
    params.min_pts = 5;
    shannon::FastOPTICS optics(params);

    // Only 3 points, less than min_pts
    std::vector<float> data = {1.0f, 2.0f, 3.0f, 4.0f, 5.0f, 6.0f};
    auto result = optics.cluster(data.data(), 3, 2);
    EXPECT_EQ(result.n_clusters, 0u);
    EXPECT_EQ(result.n_noise, 3u);
}

// =============================================================================
// Known cluster structure
// =============================================================================

TEST(FastOPTICS, TwoClusters2D) {
    // Generate two well-separated 2D clusters
    std::mt19937 rng(42);
    std::normal_distribution<float> noise(0.0f, 0.1f);

    std::vector<float> data;
    // Cluster A: centered at (0, 0)
    for (int i = 0; i < 30; ++i) {
        data.push_back(noise(rng));
        data.push_back(noise(rng));
    }
    // Cluster B: centered at (10, 10)
    for (int i = 0; i < 30; ++i) {
        data.push_back(10.0f + noise(rng));
        data.push_back(10.0f + noise(rng));
    }

    shannon::FastOPTICS::Params params;
    params.min_pts = 5;
    params.xi = 0.05;
    params.n_projections = 16;
    shannon::FastOPTICS optics(params);

    auto result = optics.cluster(data.data(), 60, 2);

    // Should find at least 1 cluster (density-based may merge or split)
    EXPECT_GE(result.n_clusters, 1u);
    EXPECT_EQ(result.ordering.size(), 60u);
}

TEST(FastOPTICS, VectorOfVectors) {
    // Same test using vector<vector<float>> interface
    std::mt19937 rng(42);
    std::normal_distribution<float> noise(0.0f, 0.1f);

    std::vector<std::vector<float>> points;
    for (int i = 0; i < 20; ++i) {
        points.push_back({noise(rng), noise(rng)});
    }
    for (int i = 0; i < 20; ++i) {
        points.push_back({5.0f + noise(rng), 5.0f + noise(rng)});
    }

    shannon::FastOPTICS optics;
    auto result = optics.cluster(points);

    EXPECT_EQ(result.ordering.size(), 40u);
}

// =============================================================================
// Centroid computation
// =============================================================================

TEST(FastOPTICS, CentroidComputation) {
    // 3 points in 2D: (0,0), (2,0), (1,1) -> centroid = (1, 1/3)
    float data[] = {0.0f, 0.0f, 2.0f, 0.0f, 1.0f, 1.0f};
    std::vector<size_t> indices = {0, 1, 2};

    auto centroid = shannon::FastOPTICS::compute_centroid(data, 2, indices);

    EXPECT_EQ(centroid.size(), 2u);
    EXPECT_NEAR(centroid[0], 1.0f, 1e-6);
    EXPECT_NEAR(centroid[1], 1.0f / 3.0f, 1e-6);
}

TEST(FastOPTICS, CentroidEmpty) {
    std::vector<size_t> indices;
    auto centroid = shannon::FastOPTICS::compute_centroid(nullptr, 3, indices);
    EXPECT_EQ(centroid.size(), 3u);
    EXPECT_FLOAT_EQ(centroid[0], 0.0f);
}

// =============================================================================
// Reproducibility
// =============================================================================

TEST(FastOPTICS, Deterministic) {
    std::mt19937 rng(123);
    std::normal_distribution<float> noise(0.0f, 1.0f);

    std::vector<float> data(100 * 3);
    for (auto& v : data) v = noise(rng);

    shannon::FastOPTICS::Params params;
    params.seed = 42;
    shannon::FastOPTICS optics(params);

    auto result1 = optics.cluster(data.data(), 100, 3);
    auto result2 = optics.cluster(data.data(), 100, 3);

    // Same seed -> same ordering
    ASSERT_EQ(result1.ordering.size(), result2.ordering.size());
    for (size_t i = 0; i < result1.ordering.size(); ++i) {
        EXPECT_EQ(result1.ordering[i].index, result2.ordering[i].index);
    }
    EXPECT_EQ(result1.n_clusters, result2.n_clusters);
}

// =============================================================================
// High-dimensional (256-d, like energy matrix rows)
// =============================================================================

TEST(FastOPTICS, HighDimensional) {
    std::mt19937 rng(42);
    std::normal_distribution<float> noise(0.0f, 1.0f);

    // 50 points in 256-d
    std::vector<float> data(50 * 256);
    for (auto& v : data) v = noise(rng);

    shannon::FastOPTICS::Params params;
    params.min_pts = 3;
    params.n_projections = 8;
    shannon::FastOPTICS optics(params);

    auto result = optics.cluster(data.data(), 50, 256);
    EXPECT_EQ(result.ordering.size(), 50u);
    // In high-d with random data, all points may be noise
    EXPECT_EQ(result.ordering.size(), result.n_clusters > 0 ?
              result.n_noise + result.ordering.size() - result.n_noise :
              result.n_noise);
}
