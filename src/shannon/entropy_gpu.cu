// entropy_gpu.cu — CUDA/ROCm GPU entropy kernels for Shannon 2.0
//
// Warp-shuffle log-sum-exp for NVIDIA GPUs.
// For ROCm/HIP, compile with hipcc instead of nvcc.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#ifdef SHANNON_USE_CUDA

#include <cuda_runtime.h>
#include <cooperative_groups.h>

namespace cg = cooperative_groups;

namespace shannon::kernels::cuda {

// ─── Warp-level reduction helpers ────────────────────────────────────────────

__device__ __forceinline__ double warp_reduce_sum(double val) {
    for (int offset = warpSize / 2; offset > 0; offset /= 2) {
        val += __shfl_down_sync(0xFFFFFFFF, val, offset);
    }
    return val;
}

__device__ __forceinline__ double warp_reduce_max(double val) {
    for (int offset = warpSize / 2; offset > 0; offset /= 2) {
        double other = __shfl_down_sync(0xFFFFFFFF, val, offset);
        val = (other > val) ? other : val;
    }
    return val;
}

// ─── CUDA kernel: configurational entropy ────────────────────────────────────
//
// One warp per entropy computation. Each thread processes multiple elements.

__global__ void configurational_entropy_kernel(
    const double* __restrict__ w,
    std::size_t n,
    double* __restrict__ result)
{
    auto g = cg::this_thread_block();
    auto warp = cg::tiled_partition<32>(g);

    double max_w = -1e300;
    double Z = 0.0;
    double ws = 0.0;

    // Each thread processes strided elements
    for (std::size_t i = warp.thread_rank(); i < n; i += warp.size()) {
        if (w[i] > max_w) max_w = w[i];
    }
    max_w = warp_reduce_max(max_w);

    for (std::size_t i = warp.thread_rank(); i < n; i += warp.size()) {
        double shifted = w[i] - max_w;
        double ev = exp(shifted);
        Z += ev;
        ws += shifted * ev;
    }

    Z = warp_reduce_sum(Z);
    ws = warp_reduce_sum(ws);

    if (warp.thread_rank() == 0) {
        if (Z <= 0.0) {
            *result = 0.0;
        } else {
            constexpr double ln2 = 0.693147180559945309417;
            double log2_Z = log2(Z);
            double entropy = log2_Z - (ws / (Z * ln2));
            *result = (entropy > 0.0) ? entropy : 0.0;
        }
    }
}

// ─── Host-side launcher ─────────────────────────────────────────────────────

double configurational_entropy_cuda(const double* w, std::size_t n) {
    if (n <= 1) return 0.0;

    double* d_w = nullptr;
    double* d_result = nullptr;

    cudaError_t err;
    err = cudaMalloc(&d_w, n * sizeof(double));
    if (err != cudaSuccess) return 0.0;

    err = cudaMalloc(&d_result, sizeof(double));
    if (err != cudaSuccess) {
        cudaFree(d_w);
        return 0.0;
    }

    cudaMemcpy(d_w, w, n * sizeof(double), cudaMemcpyHostToDevice);

    // Launch with 1 warp (32 threads), 1 block
    configurational_entropy_kernel<<<1, 32>>>(d_w, n, d_result);
    cudaDeviceSynchronize();

    double h_result = 0.0;
    cudaMemcpy(&h_result, d_result, sizeof(double), cudaMemcpyDeviceToHost);

    cudaFree(d_w);
    cudaFree(d_result);

    return h_result;
}

}  // namespace shannon::kernels::cuda

#endif  // SHANNON_USE_CUDA
