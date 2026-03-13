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

// Release device buffers
void shannon_cuda_shutdown();

// Query GPU availability
bool shannon_cuda_available();

}  // namespace cuda
}  // namespace shannon

#endif  // SHANNON_HAS_CUDA
