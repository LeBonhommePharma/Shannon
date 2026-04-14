// entropy_metal.metal — Metal GPU entropy kernel for Shannon 2.0
//
// Uses threadgroup shared memory for parallel reduction on Apple GPUs.
// Compile with: xcrun -sdk macosx metal -c entropy_metal.metal -o entropy_metal.air
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include <metal_stdlib>
using namespace metal;

// ─── Configurational entropy kernel (Metal) ─────────────────────────────────
//
// One threadgroup computes one entropy value from n log-weights.

kernel void configurational_entropy_metal(
    device const double* w        [[buffer(0)]],
    device double*       result   [[buffer(1)]],
    constant uint&       n        [[buffer(2)]],
    threadgroup double*  tg_mem   [[threadgroup(0)]],
    uint                 tid      [[thread_index_in_threadgroup]],
    uint                 group_id [[threadgroup_position_in_grid]],
    uint                 group_sz [[threads_per_threadgroup]])
{
    // Step 1: parallel max reduction
    double local_max = -1e300;
    for (uint i = tid; i < n; i += group_sz) {
        if (w[i] > local_max) local_max = w[i];
    }
    tg_mem[tid] = local_max;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint stride = group_sz / 2; stride > 0; stride /= 2) {
        if (tid < stride) {
            if (tg_mem[tid + stride] > tg_mem[tid]) {
                tg_mem[tid] = tg_mem[tid + stride];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    double max_w = tg_mem[0];

    // Step 2: compute Z and weighted sum
    double local_Z = 0.0;
    double local_ws = 0.0;
    constexpr double ln2 = 0.693147180559945309417;

    for (uint i = tid; i < n; i += group_sz) {
        double shifted = w[i] - max_w;
        double ev = exp(shifted);
        local_Z += ev;
        local_ws += shifted * ev;
    }

    // Sum Z across threadgroup
    tg_mem[tid] = local_Z;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = group_sz / 2; stride > 0; stride /= 2) {
        if (tid < stride) tg_mem[tid] += tg_mem[tid + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    double Z = tg_mem[0];

    // Sum ws across threadgroup
    tg_mem[tid] = local_ws;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = group_sz / 2; stride > 0; stride /= 2) {
        if (tid < stride) tg_mem[tid] += tg_mem[tid + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    double ws = tg_mem[0];

    // Step 3: compute entropy
    if (tid == 0) {
        if (Z <= 0.0) {
            *result = 0.0;
        } else {
            double log2_Z = log2(Z);
            double entropy = log2_Z - (ws / (Z * ln2));
            *result = (entropy > 0.0) ? entropy : 0.0;
        }
    }
}
