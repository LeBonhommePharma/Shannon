#pragma once
// =============================================================================
// Shannon CUDA Kernels — GPU-accelerated entropy computation
//
// Ported from FlexAIDdS kernel_shannon_histogram():
//   - Shared-memory local accumulation + global atomic merge
//   - ~56x speedup on A100/RTX 4090 vs CPU scalar
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#ifdef SHANNON_HAS_CUDA

#include <cstddef>

namespace shannon {
namespace cuda {

// Initialize CUDA context and allocate device buffers
// Call once at startup; thread-safe
bool shannon_cuda_init(size_t max_vocab_size = 131072);

// Compute Shannon entropy on GPU
// Returns entropy in bits. Falls back to CPU if CUDA unavailable.
double shannon_cuda_entropy(const double* host_probs, size_t n);

// Compute entropy from logits on GPU (fused log-sum-exp + entropy)
double shannon_cuda_entropy_from_logits(const double* host_logits, size_t n);

// Compute weighted entropy on GPU with energy matrix context
// matrix_data: flat 256x256 float energy matrix on host
// token_ids: context token IDs
double shannon_cuda_weighted_entropy(
    const double* host_probs, size_t n,
    const float* matrix_data,
    const unsigned char* token_ids, size_t context_len);

// Compute pairwise Euclidean distance matrix on GPU (for FastOPTICS)
// data: (n, d) row-major float array on host
// dist_out: (n, n) output distance matrix on host
void shannon_cuda_pairwise_distances(
    const float* host_data, size_t n, size_t d,
    float* dist_out);

// Release device buffers
void shannon_cuda_shutdown();

// Batch matrix lookup on GPU: scores[k] = matrix[types_i[k] * 256 + types_j[k]]
// Uses constant-memory cached energy matrix
void shannon_cuda_batch_lookup(
    const unsigned char* types_i, const unsigned char* types_j,
    float* scores, size_t n);

// Batch pose scoring on GPU: per-pose sum of matrix[ti][tj] * f(r)
// types_i/types_j: [n_poses * contacts_per_pose], distances: [n_poses * contacts_per_pose]
void shannon_cuda_batch_pose_score(
    const unsigned char* types_i, const unsigned char* types_j,
    const float* distances, float* scores,
    size_t n_poses, size_t contacts_per_pose);

// Query GPU availability
bool shannon_cuda_available();

}  // namespace cuda
}  // namespace shannon

#endif  // SHANNON_HAS_CUDA
