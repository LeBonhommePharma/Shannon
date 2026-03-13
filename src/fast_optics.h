#pragma once
// =============================================================================
// FastOPTICS — Linear-Time Density-Based Clustering for Super-Cluster Extraction
//
// Ported from FlexAIDdS LIB/fast_optics.cpp.
// Used to identify super-clusters in the 256x256 energy matrix when entropy
// collapse is detected. Each pose/token becomes a 256-d vector (row activations),
// and FastOPTICS clusters these to find the dominant interaction pattern.
//
// Key properties:
//   - Linear time: O(n * d * n_projections)
//   - Density-based: no predetermined number of clusters
//   - Hierarchical: produces reachability plot for OPTICS ordering
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <cstddef>
#include <cstdint>
#include <vector>

namespace shannon {

// =============================================================================
// FastOPTICS result types
// =============================================================================

struct OPTICSPoint {
    size_t index;              // Original point index
    double reachability_dist;  // Reachability distance (OPTICS ordering)
    double core_dist;          // Core distance
    int cluster_id;            // Assigned cluster (-1 = noise)
};

struct ClusterResult {
    std::vector<OPTICSPoint> ordering;           // OPTICS ordering
    std::vector<std::vector<size_t>> clusters;   // Cluster assignments
    std::vector<std::vector<float>> centroids;   // Cluster centroids
    size_t n_clusters;                           // Number of clusters found
    size_t n_noise;                              // Number of noise points
};

// =============================================================================
// FastOPTICS — Main class
// =============================================================================

struct FastOPTICSParams {
    size_t min_pts = 5;            // Minimum points for core point
    size_t n_projections = 16;     // Number of random projections
    double xi = 0.05;             // Steepness threshold for cluster extraction
    uint32_t seed = 42;            // RNG seed for reproducibility
};

class FastOPTICS {
public:
    using Params = FastOPTICSParams;

    explicit FastOPTICS(Params params = {});

    // Run clustering on n points of dimension d
    // data: row-major float array of shape (n, d)
    ClusterResult cluster(const float* data, size_t n, size_t d) const;

    // Convenience: cluster using vector of vectors
    ClusterResult cluster(const std::vector<std::vector<float>>& points) const;

    // Extract super-cluster: the largest cluster's centroid + members
    static std::vector<float> compute_centroid(
        const float* data, size_t d,
        const std::vector<size_t>& member_indices);

    const Params& params() const noexcept { return params_; }

private:
    Params params_;

    // Random projections for approximate nearest-neighbor ordering
    struct Projection {
        std::vector<float> direction;  // unit vector in R^d
        std::vector<std::pair<float, size_t>> sorted_projections;  // (projected_value, index)
    };

    // Internal methods
    std::vector<Projection> generate_projections(size_t d, size_t n) const;
    void compute_core_distances(
        const float* data, size_t n, size_t d,
        const std::vector<Projection>& projections,
        std::vector<double>& core_dists) const;
    std::vector<OPTICSPoint> optics_ordering(
        const float* data, size_t n, size_t d,
        const std::vector<double>& core_dists,
        const std::vector<Projection>& projections) const;
    std::vector<std::vector<size_t>> extract_clusters(
        const std::vector<OPTICSPoint>& ordering) const;

    static double euclidean_distance(const float* a, const float* b, size_t d);
};

}  // namespace shannon
