#pragma once
// =============================================================================
// Shannon Metal Kernels — GPU-accelerated entropy computation (Apple Silicon)
//
// Full Metal compute shader implementation for:
//   - Shannon entropy from probabilities
//   - Fused log-sum-exp entropy from logits
//   - Weighted entropy with 256x256 energy matrix
//   - Pairwise distance computation for FastOPTICS
//
// Hardware: Apple M1/M2/M3/M4 GPU via Metal Performance Shaders
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#ifdef SHANNON_HAS_METAL

#include <cstddef>

namespace shannon {
namespace metal {

// Initialize Metal context — discovers device, compiles shaders, allocates buffers
// Call once at startup; thread-safe
bool shannon_metal_init(size_t max_vocab_size = 131072);

// Compute Shannon entropy on GPU: H = -sum(p_i * log2(p_i))
double shannon_metal_entropy(const double* host_probs, size_t n);

// Compute entropy from logits on GPU (fused log-sum-exp + entropy)
double shannon_metal_entropy_from_logits(const double* host_logits, size_t n);

// Compute weighted entropy with 256x256 energy matrix context
double shannon_metal_weighted_entropy(
    const double* host_probs, size_t n,
    const float* matrix_data,
    const unsigned char* token_ids, size_t context_len);

// Compute pairwise Euclidean distance matrix for FastOPTICS
void shannon_metal_pairwise_distances(
    const float* host_data, size_t n, size_t d,
    float* dist_out);

// Release Metal resources
void shannon_metal_shutdown();

// Query Metal GPU availability
bool shannon_metal_available();

}  // namespace metal
}  // namespace shannon

#endif  // SHANNON_HAS_METAL
