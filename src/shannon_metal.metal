// =============================================================================
// Shannon Metal Compute Shaders — Apple Silicon GPU acceleration
//
// Implements parallel reduction for entropy computation using Metal Shading
// Language. Each kernel uses threadgroup shared memory for local accumulation
// followed by hierarchical reduction.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <metal_stdlib>
using namespace metal;

// =============================================================================
// Kernel: Shannon entropy from probabilities
// H = -sum(p_i * log2(p_i))
// =============================================================================

kernel void entropy_from_probs(
    device const float* probs [[buffer(0)]],
    device float* partial_sums [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint tg_id [[threadgroup_position_in_grid]],
    threadgroup float* shared [[threadgroup(0)]]
) {
    uint stride = tg_size * (n / (tg_size * 256) + 1);  // grid stride
    float local_h = 0.0f;

    for (uint i = gid; i < n; i += stride) {
        float p = probs[i];
        if (p > 0.0f) {
            local_h -= p * log2(p);
        }
    }

    shared[tid] = local_h;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Reduction within threadgroup
    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared[tid] += shared[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        partial_sums[tg_id] = shared[0];
    }
}

// =============================================================================
// Kernel: Find max logit (parallel reduction)
// =============================================================================

kernel void find_max_logit(
    device const float* logits [[buffer(0)]],
    device float* partial_max [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint tg_id [[threadgroup_position_in_grid]],
    threadgroup float* shared [[threadgroup(0)]]
) {
    float local_max = -INFINITY;

    for (uint i = gid; i < n; i += tg_size * 256) {
        if (logits[i] > local_max) local_max = logits[i];
    }

    shared[tid] = local_max;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            if (shared[tid + s] > shared[tid]) shared[tid] = shared[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        partial_max[tg_id] = shared[0];
    }
}

// =============================================================================
// Kernel: Fused log-sum-exp + entropy from logits
// Computes sum(exp(x-max)) and sum(x*exp(x-max)) in a single pass
// =============================================================================

kernel void entropy_from_logits(
    device const float* logits [[buffer(0)]],
    device float* partial_sum_exp [[buffer(1)]],
    device float* partial_sum_x_exp [[buffer(2)]],
    constant float& max_logit [[buffer(3)]],
    constant uint& n [[buffer(4)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint tg_id [[threadgroup_position_in_grid]],
    threadgroup float* shared_exp [[threadgroup(0)]],
    threadgroup float* shared_x_exp [[threadgroup(1)]]
) {
    float local_sum_exp = 0.0f;
    float local_sum_x_exp = 0.0f;

    for (uint i = gid; i < n; i += tg_size * 256) {
        float shifted = logits[i] - max_logit;
        float e = exp(shifted);
        local_sum_exp += e;
        local_sum_x_exp += logits[i] * e;
    }

    shared_exp[tid] = local_sum_exp;
    shared_x_exp[tid] = local_sum_x_exp;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) {
            shared_exp[tid] += shared_exp[tid + s];
            shared_x_exp[tid] += shared_x_exp[tid + s];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) {
        partial_sum_exp[tg_id] = shared_exp[0];
        partial_sum_x_exp[tg_id] = shared_x_exp[0];
    }
}

// =============================================================================
// Kernel: Weighted entropy with 256x256 energy matrix
// =============================================================================

kernel void weighted_entropy(
    device const float* probs [[buffer(0)]],
    device const float* energy_matrix [[buffer(1)]],  // 256x256 flat
    device const uchar* token_ids [[buffer(2)]],
    device float* partial_sums [[buffer(3)]],
    constant uint& n [[buffer(4)]],
    constant uint& context_len [[buffer(5)]],
    constant float& inv_context [[buffer(6)]],
    uint gid [[thread_position_in_grid]],
    uint tid [[thread_position_in_threadgroup]],
    uint tg_size [[threads_per_threadgroup]],
    uint tg_id [[threadgroup_position_in_grid]],
    threadgroup float* shared [[threadgroup(0)]]
) {
    float local_h = 0.0f;

    for (uint i = gid; i < n; i += tg_size * 256) {
        float p = probs[i];
        if (p <= 0.0f) continue;

        uchar ti = uchar(i % 256);

        // Average energy with context tokens
        float w = 0.0f;
        for (uint c = 0; c < context_len; ++c) {
            w += energy_matrix[uint(ti) * 256 + uint(token_ids[c])];
        }
        w *= inv_context;

        float weight = exp(-w);
        local_h -= weight * p * log2(p);
    }

    shared[tid] = local_h;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint s = tg_size / 2; s > 0; s >>= 1) {
        if (tid < s) shared[tid] += shared[tid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    if (tid == 0) partial_sums[tg_id] = shared[0];
}

// =============================================================================
// Kernel: Pairwise Euclidean distance matrix for FastOPTICS
// =============================================================================

kernel void pairwise_distances(
    device const float* data [[buffer(0)]],
    device float* dist_out [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    constant uint& d [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint row = gid.y;
    uint col = gid.x;

    if (row >= n || col >= n) return;

    // Only compute upper triangle + diagonal
    if (col < row) {
        dist_out[row * n + col] = dist_out[col * n + row];
        return;
    }

    float sum = 0.0f;
    for (uint k = 0; k < d; ++k) {
        float diff = data[row * d + k] - data[col * d + k];
        sum += diff * diff;
    }
    dist_out[row * n + col] = sqrt(sum);
}

// =============================================================================
// Kernel: Batch matrix lookup — scores[k] = matrix[types_i[k] * 256 + types_j[k]]
// =============================================================================

kernel void batch_matrix_lookup(
    device const uchar* types_i [[buffer(0)]],
    device const uchar* types_j [[buffer(1)]],
    device float* scores [[buffer(2)]],
    constant float* energy_matrix [[buffer(3)]],
    constant uint& n [[buffer(4)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= n) return;
    uint idx = uint(types_i[gid]) * 256 + uint(types_j[gid]);
    scores[gid] = energy_matrix[idx];
}
