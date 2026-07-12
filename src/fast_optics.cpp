// =============================================================================
// FastOPTICS — Linear-Time Density-Based Clustering
//
// Ported from FlexAIDdS LIB/fast_optics.cpp.
// Implements the FastOPTICS algorithm (Schneider & Vlachos, 2013) using
// random projections for approximate nearest-neighbor computation.
//
// Hardware acceleration:
//   - OpenMP parallel projection + distance computation
//   - AVX2/AVX-512 accelerated Euclidean distance (via SIMD dispatch)
//   - C++20 structured bindings, std::erase_if
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include "fast_optics.h"
#include <algorithm>
#include <cmath>
#include <limits>
#include <numeric>
#include <random>
#include <queue>

// Prefer SHANNON_USE_* (set by CMake); accept SHANNON_HAS_* as aliases.
#if defined(SHANNON_USE_AVX512) && !defined(SHANNON_HAS_AVX512)
#  define SHANNON_HAS_AVX512 1
#endif
#if defined(SHANNON_USE_AVX2) && !defined(SHANNON_HAS_AVX2)
#  define SHANNON_HAS_AVX2 1
#endif
#if defined(SHANNON_USE_OPENMP) && !defined(SHANNON_HAS_OPENMP)
#  define SHANNON_HAS_OPENMP 1
#endif
#if defined(SHANNON_USE_NEON) && !defined(SHANNON_HAS_NEON)
#  define SHANNON_HAS_NEON 1
#endif

#ifdef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif

#ifdef SHANNON_HAS_AVX2
#ifndef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif
#endif

#if defined(SHANNON_HAS_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
#include <arm_neon.h>
#endif

#ifdef SHANNON_HAS_OPENMP
#include <omp.h>
#endif

namespace shannon {

FastOPTICS::FastOPTICS(Params params) : params_(params) {}

// =============================================================================
// SIMD-accelerated Euclidean distance — same dispatch pattern as shannon.cpp
// =============================================================================

double FastOPTICS::euclidean_distance(const float* a, const float* b, size_t d) {
#ifdef SHANNON_HAS_AVX512
    // 16-wide float SIMD
    __m512 acc = _mm512_setzero_ps();
    size_t i = 0;
    const size_t vec_end = d - (d % 16);
    for (; i < vec_end; i += 16) {
        __m512 va = _mm512_loadu_ps(a + i);
        __m512 vb = _mm512_loadu_ps(b + i);
        __m512 diff = _mm512_sub_ps(va, vb);
        acc = _mm512_fmadd_ps(diff, diff, acc);
    }
    double sum = static_cast<double>(_mm512_reduce_add_ps(acc));
    for (; i < d; ++i) {
        double diff = static_cast<double>(a[i]) - static_cast<double>(b[i]);
        sum += diff * diff;
    }
    return std::sqrt(sum);
#elif defined(SHANNON_HAS_AVX2)
    // 8-wide float SIMD with FMA
    __m256 acc = _mm256_setzero_ps();
    size_t i = 0;
    const size_t vec_end = d - (d % 8);
    for (; i < vec_end; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        __m256 diff = _mm256_sub_ps(va, vb);
        acc = _mm256_fmadd_ps(diff, diff, acc);
    }
    // Horizontal sum
    alignas(32) float result[8];
    _mm256_store_ps(result, acc);
    double sum = 0.0;
    for (int k = 0; k < 8; ++k) sum += static_cast<double>(result[k]);
    for (; i < d; ++i) {
        double diff = static_cast<double>(a[i]) - static_cast<double>(b[i]);
        sum += diff * diff;
    }
    return std::sqrt(sum);
#elif defined(SHANNON_HAS_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
    // 4-wide float NEON with FMA
    float32x4_t acc = vdupq_n_f32(0.0f);
    size_t i = 0;
    const size_t vec_end = d - (d % 4);
    for (; i < vec_end; i += 4) {
        float32x4_t va = vld1q_f32(a + i);
        float32x4_t vb = vld1q_f32(b + i);
        float32x4_t diff = vsubq_f32(va, vb);
        acc = vfmaq_f32(acc, diff, diff);
    }
    float32x2_t s2 = vadd_f32(vget_low_f32(acc), vget_high_f32(acc));
    double sum = static_cast<double>(vget_lane_f32(vpadd_f32(s2, s2), 0));
    for (; i < d; ++i) {
        double diff = static_cast<double>(a[i]) - static_cast<double>(b[i]);
        sum += diff * diff;
    }
    return std::sqrt(sum);
#else
    // Scalar fallback
    double sum = 0.0;
    for (size_t i = 0; i < d; ++i) {
        double diff = static_cast<double>(a[i]) - static_cast<double>(b[i]);
        sum += diff * diff;
    }
    return std::sqrt(sum);
#endif
}

// =============================================================================
// Random projection generation
// =============================================================================

std::vector<FastOPTICS::Projection> FastOPTICS::generate_projections(
    size_t d, [[maybe_unused]] size_t n
) const {
    std::mt19937 rng(params_.seed);
    std::normal_distribution<float> normal(0.0f, 1.0f);

    std::vector<Projection> projections(params_.n_projections);

    for (auto& proj : projections) {
        proj.direction.resize(d);
        float norm = 0.0f;
        for (size_t i = 0; i < d; ++i) {
            proj.direction[i] = normal(rng);
            norm += proj.direction[i] * proj.direction[i];
        }
        norm = std::sqrt(norm);
        for (size_t i = 0; i < d; ++i) {
            proj.direction[i] /= norm;
        }
    }

    return projections;
}

// =============================================================================
// Core distance computation — OpenMP parallelized
// =============================================================================

void FastOPTICS::compute_core_distances(
    const float* data, size_t n, size_t d,
    const std::vector<Projection>& projections,
    std::vector<double>& core_dists
) const {
    core_dists.assign(n, std::numeric_limits<double>::infinity());

    for (const auto& proj : projections) {
        // Project all points — OpenMP parallel for large n
        std::vector<std::pair<float, size_t>> projected(n);

#ifdef SHANNON_HAS_OPENMP
        if (n > 1000) {
            #pragma omp parallel for
            for (size_t i = 0; i < n; ++i) {
                float val = 0.0f;
                for (size_t k = 0; k < d; ++k) {
                    val += data[i * d + k] * proj.direction[k];
                }
                projected[i] = {val, i};
            }
        } else
#endif
        {
            for (size_t i = 0; i < n; ++i) {
                float val = 0.0f;
                for (size_t k = 0; k < d; ++k) {
                    val += data[i * d + k] * proj.direction[k];
                }
                projected[i] = {val, i};
            }
        }

        // Sort by projected value
        std::sort(projected.begin(), projected.end());

        // For each point, find min_pts nearest neighbors in sorted order
#ifdef SHANNON_HAS_OPENMP
        if (n > 1000) {
            #pragma omp parallel for
            for (size_t pos = 0; pos < n; ++pos) {
                size_t idx = projected[pos].second;
                size_t window = std::min(params_.min_pts * 2 + 1, n);
                size_t start = (pos >= window / 2) ? pos - window / 2 : 0;
                size_t end = std::min(start + window, n);
                if (end == n && n >= window) start = n - window;

                std::vector<double> neighbor_dists;
                neighbor_dists.reserve(window);
                for (size_t j = start; j < end; ++j) {
                    if (j == pos) continue;
                    size_t neighbor_idx = projected[j].second;
                    neighbor_dists.push_back(
                        euclidean_distance(data + idx * d, data + neighbor_idx * d, d));
                }

                std::sort(neighbor_dists.begin(), neighbor_dists.end());
                if (neighbor_dists.size() >= params_.min_pts) {
                    double cd = neighbor_dists[params_.min_pts - 1];
                    #pragma omp critical
                    {
                        core_dists[idx] = std::min(core_dists[idx], cd);
                    }
                }
            }
        } else
#endif
        {
            for (size_t pos = 0; pos < n; ++pos) {
                size_t idx = projected[pos].second;
                size_t window = std::min(params_.min_pts * 2 + 1, n);
                size_t start = (pos >= window / 2) ? pos - window / 2 : 0;
                size_t end = std::min(start + window, n);
                if (end == n && n >= window) start = n - window;

                std::vector<double> neighbor_dists;
                neighbor_dists.reserve(window);
                for (size_t j = start; j < end; ++j) {
                    if (j == pos) continue;
                    size_t neighbor_idx = projected[j].second;
                    neighbor_dists.push_back(
                        euclidean_distance(data + idx * d, data + neighbor_idx * d, d));
                }

                std::sort(neighbor_dists.begin(), neighbor_dists.end());
                if (neighbor_dists.size() >= params_.min_pts) {
                    double cd = neighbor_dists[params_.min_pts - 1];
                    core_dists[idx] = std::min(core_dists[idx], cd);
                }
            }
        }
    }
}

// =============================================================================
// OPTICS ordering — sequential (inherently order-dependent)
// =============================================================================

std::vector<OPTICSPoint> FastOPTICS::optics_ordering(
    const float* data, size_t n, size_t d,
    const std::vector<double>& core_dists,
    [[maybe_unused]] const std::vector<Projection>& projections
) const {
    std::vector<OPTICSPoint> ordering;
    ordering.reserve(n);

    std::vector<bool> processed(n, false);
    std::vector<double> reachability(n, std::numeric_limits<double>::infinity());

    using PQEntry = std::pair<double, size_t>;
    std::priority_queue<PQEntry, std::vector<PQEntry>, std::greater<>> pq;

    for (size_t seed = 0; seed < n; ++seed) {
        if (processed[seed]) continue;

        processed[seed] = true;
        ordering.push_back(OPTICSPoint{seed, reachability[seed], core_dists[seed], -1});

        if (core_dists[seed] == std::numeric_limits<double>::infinity()) continue;

        // Update reachability of unprocessed neighbors
        for (size_t j = 0; j < n; ++j) {
            if (processed[j]) continue;
            double dist = euclidean_distance(data + seed * d, data + j * d, d);
            double new_reach = std::max(core_dists[seed], dist);
            if (new_reach < reachability[j]) {
                reachability[j] = new_reach;
                pq.push({new_reach, j});
            }
        }

        while (!pq.empty()) {
            auto [reach, idx] = pq.top();
            pq.pop();
            if (processed[idx]) continue;

            processed[idx] = true;
            ordering.push_back(OPTICSPoint{idx, reachability[idx], core_dists[idx], -1});

            if (core_dists[idx] == std::numeric_limits<double>::infinity()) continue;

            for (size_t j = 0; j < n; ++j) {
                if (processed[j]) continue;
                double dist = euclidean_distance(data + idx * d, data + j * d, d);
                double new_reach = std::max(core_dists[idx], dist);
                if (new_reach < reachability[j]) {
                    reachability[j] = new_reach;
                    pq.push({new_reach, j});
                }
            }
        }
    }

    return ordering;
}

// =============================================================================
// Xi cluster extraction from reachability plot
// =============================================================================

std::vector<std::vector<size_t>> FastOPTICS::extract_clusters(
    const std::vector<OPTICSPoint>& ordering
) const {
    std::vector<std::vector<size_t>> clusters;
    if (ordering.empty()) return clusters;

    std::vector<int> labels(ordering.size(), -1);
    int current_cluster = -1;
    bool in_cluster = false;

    double prev_reach = ordering[0].reachability_dist;
    if (prev_reach == std::numeric_limits<double>::infinity()) {
        prev_reach = 0.0;
    }

    for (size_t i = 1; i < ordering.size(); ++i) {
        double curr_reach = ordering[i].reachability_dist;
        if (curr_reach == std::numeric_limits<double>::infinity()) {
            in_cluster = false;
            prev_reach = curr_reach;
            continue;
        }

        // Steep down: entering a cluster
        if (prev_reach != std::numeric_limits<double>::infinity() &&
            curr_reach <= prev_reach * (1.0 - params_.xi)) {
            if (!in_cluster) {
                current_cluster++;
                in_cluster = true;
            }
        }

        // Steep up: leaving a cluster
        if (prev_reach != std::numeric_limits<double>::infinity() &&
            prev_reach > 0 &&
            curr_reach >= prev_reach * (1.0 + params_.xi)) {
            in_cluster = false;
        }

        if (in_cluster) {
            labels[i] = current_cluster;
        }

        prev_reach = curr_reach;
    }

    // Group by cluster label
    int n_clusters = current_cluster + 1;
    clusters.resize(n_clusters);
    for (size_t i = 0; i < ordering.size(); ++i) {
        if (labels[i] >= 0) {
            clusters[labels[i]].push_back(ordering[i].index);
        }
    }

    // C++20: std::erase_if
    std::erase_if(clusters, [](const auto& c) { return c.empty(); });

    return clusters;
}

// =============================================================================
// Main clustering entry point
// =============================================================================

ClusterResult FastOPTICS::cluster(const float* data, size_t n, size_t d) const {
    ClusterResult result;

    if (n == 0) {
        result.n_clusters = 0;
        result.n_noise = 0;
        return result;
    }

    if (n < params_.min_pts) {
        result.ordering.resize(n);
        for (size_t i = 0; i < n; ++i) {
            result.ordering[i] = OPTICSPoint{i, std::numeric_limits<double>::infinity(),
                                              std::numeric_limits<double>::infinity(), -1};
        }
        result.n_clusters = 0;
        result.n_noise = n;
        return result;
    }

    auto projections = generate_projections(d, n);

    std::vector<double> core_dists;
    compute_core_distances(data, n, d, projections, core_dists);

    result.ordering = optics_ordering(data, n, d, core_dists, projections);

    result.clusters = extract_clusters(result.ordering);
    result.n_clusters = result.clusters.size();

    // Compute centroids — OpenMP parallel for large clusters
    result.centroids.resize(result.n_clusters);
    for (size_t c = 0; c < result.n_clusters; ++c) {
        result.centroids[c] = compute_centroid(data, d, result.clusters[c]);
    }

    // Build index map for O(1) cluster assignment
    std::vector<int> index_to_cluster(n, -1);
    for (size_t c = 0; c < result.n_clusters; ++c) {
        for (size_t idx : result.clusters[c]) {
            index_to_cluster[idx] = static_cast<int>(c);
        }
    }
    for (auto& pt : result.ordering) {
        pt.cluster_id = index_to_cluster[pt.index];
    }

    // Count noise
    result.n_noise = 0;
    for (const auto& pt : result.ordering) {
        if (pt.cluster_id < 0) result.n_noise++;
    }

    return result;
}

ClusterResult FastOPTICS::cluster(const std::vector<std::vector<float>>& points) const {
    if (points.empty()) {
        return cluster(nullptr, 0, 0);
    }

    size_t n = points.size();
    size_t d = points[0].size();

    std::vector<float> flat(n * d);
    for (size_t i = 0; i < n; ++i) {
        for (size_t j = 0; j < d; ++j) {
            flat[i * d + j] = points[i][j];
        }
    }

    return cluster(flat.data(), n, d);
}

// =============================================================================
// Centroid computation — OpenMP parallel reduction
// =============================================================================

std::vector<float> FastOPTICS::compute_centroid(
    const float* data, size_t d,
    const std::vector<size_t>& member_indices
) {
    std::vector<float> centroid(d, 0.0f);
    if (member_indices.empty()) return centroid;

    size_t n_members = member_indices.size();

#ifdef SHANNON_HAS_OPENMP
    if (n_members * d > 10000) {
        // Parallel accumulation for large centroid computation
        #pragma omp parallel
        {
            std::vector<float> local(d, 0.0f);
            #pragma omp for nowait
            for (size_t m = 0; m < n_members; ++m) {
                size_t idx = member_indices[m];
                for (size_t k = 0; k < d; ++k) {
                    local[k] += data[idx * d + k];
                }
            }
            #pragma omp critical
            {
                for (size_t k = 0; k < d; ++k) {
                    centroid[k] += local[k];
                }
            }
        }
    } else
#endif
    {
        for (size_t idx : member_indices) {
            for (size_t k = 0; k < d; ++k) {
                centroid[k] += data[idx * d + k];
            }
        }
    }

    float inv_n = 1.0f / static_cast<float>(n_members);
    for (size_t k = 0; k < d; ++k) {
        centroid[k] *= inv_n;
    }

    return centroid;
}

}  // namespace shannon
