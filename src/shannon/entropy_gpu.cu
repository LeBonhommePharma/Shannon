// entropy_gpu.cu — CUDA GPU entropy kernels for Shannon 2.0
//
// Block-level log-sum-exp with shared-memory reduction.
//
// Correctness notes (fixes vs the original single-warp version):
//   * The reduced max is BROADCAST to all threads before the shift pass.
//     __shfl_down_sync leaves the reduction result in lane 0 only; using it
//     unbroadcast made every other lane shift against a partial max and
//     produced a wrong Z and wrong entropy.
//   * One block of 256 threads instead of a single warp — a 128k vocabulary
//     gets ~500 elements per thread instead of 4k per lane.
//   * Device buffers are cached and grown geometrically instead of
//     cudaMalloc/cudaFree per call, which dominated per-token latency.
//   * All CUDA errors surface as a negative return so the dispatcher can
//     fall back to a CPU kernel (entropy is always >= 0).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#ifdef SHANNON_USE_CUDA

#include <cuda_runtime.h>

#include <cstddef>

namespace shannon::kernels::cuda {

namespace {

constexpr int kBlockThreads = 256;
constexpr int kWarpSize     = 32;
constexpr int kNumWarps     = kBlockThreads / kWarpSize;

__device__ __forceinline__ double warp_reduce_sum(double val) {
    for (int offset = kWarpSize / 2; offset > 0; offset /= 2) {
        val += __shfl_down_sync(0xFFFFFFFF, val, offset);
    }
    return val;
}

__device__ __forceinline__ double warp_reduce_max(double val) {
    for (int offset = kWarpSize / 2; offset > 0; offset /= 2) {
        const double other = __shfl_down_sync(0xFFFFFFFF, val, offset);
        val = (other > val) ? other : val;
    }
    return val;
}

// Block-wide max, result valid in ALL threads (broadcast via shared memory).
__device__ double block_reduce_max_broadcast(double val, double* shared) {
    const int lane = threadIdx.x % kWarpSize;
    const int warp = threadIdx.x / kWarpSize;

    val = warp_reduce_max(val);          // lane 0 of each warp holds warp max
    if (lane == 0) shared[warp] = val;
    __syncthreads();

    if (warp == 0) {
        double v = (lane < kNumWarps) ? shared[lane] : -1e300;
        v = warp_reduce_max(v);          // lane 0 holds block max
        if (lane == 0) shared[0] = v;
    }
    __syncthreads();
    return shared[0];                    // broadcast to every thread
}

// Block-wide sum, result valid in thread 0 only (sufficient: thread 0 writes).
__device__ double block_reduce_sum(double val, double* shared) {
    const int lane = threadIdx.x % kWarpSize;
    const int warp = threadIdx.x / kWarpSize;

    val = warp_reduce_sum(val);
    if (lane == 0) shared[warp] = val;
    __syncthreads();

    double v = 0.0;
    if (warp == 0) {
        v = (lane < kNumWarps) ? shared[lane] : 0.0;
        v = warp_reduce_sum(v);
    }
    __syncthreads();                     // shared[] reused by the next reduction
    return v;
}

// ─── Kernel: configurational entropy (log-sum-exp from logits) ──────────────
//
//   H = log2(Z) - (1/(Z·ln2)) · Σ (w_i − max) · e^(w_i − max),  Z = Σ e^(w_i − max)

__global__ void configurational_entropy_kernel(
    const double* __restrict__ w,
    std::size_t n,
    double* __restrict__ result)
{
    __shared__ double shared[kNumWarps];

    // Pass 1: max
    double max_w = -1e300;
    for (std::size_t i = threadIdx.x; i < n; i += blockDim.x) {
        if (w[i] > max_w) max_w = w[i];
    }
    max_w = block_reduce_max_broadcast(max_w, shared);   // valid in ALL threads

    // Pass 2: Z and weighted sum against the true block max
    double Z  = 0.0;
    double ws = 0.0;
    for (std::size_t i = threadIdx.x; i < n; i += blockDim.x) {
        const double shifted = w[i] - max_w;
        const double ev = exp(shifted);
        Z  += ev;
        ws += shifted * ev;
    }
    Z = block_reduce_sum(Z, shared);
    __syncthreads();
    ws = block_reduce_sum(ws, shared);

    if (threadIdx.x == 0) {
        if (Z <= 0.0) {
            *result = 0.0;
        } else {
            constexpr double ln2 = 0.693147180559945309417;
            const double entropy = log2(Z) - (ws / (Z * ln2));
            *result = (entropy > 0.0) ? entropy : 0.0;
        }
    }
}

// ─── Cached device buffers ──────────────────────────────────────────────────
//
// Per-token streaming calls this at kHz rates; cudaMalloc/cudaFree per call
// costs far more than the kernel. Cache the input buffer per host thread and
// grow geometrically.

struct DeviceCache {
    double*     d_w      = nullptr;
    double*     d_result = nullptr;
    std::size_t capacity = 0;

    ~DeviceCache() {
        // Best-effort; at thread exit the context may already be torn down.
        if (d_w)      cudaFree(d_w);
        if (d_result) cudaFree(d_result);
    }

    bool ensure(std::size_t n) {
        if (d_result == nullptr &&
            cudaMalloc(&d_result, sizeof(double)) != cudaSuccess) {
            d_result = nullptr;
            return false;
        }
        if (n <= capacity) return true;

        std::size_t new_cap = (capacity == 0) ? 1024 : capacity;
        while (new_cap < n) new_cap *= 2;

        if (d_w) { cudaFree(d_w); d_w = nullptr; capacity = 0; }
        if (cudaMalloc(&d_w, new_cap * sizeof(double)) != cudaSuccess) {
            d_w = nullptr;
            return false;
        }
        capacity = new_cap;
        return true;
    }
};

}  // namespace

// ─── Host-side launcher ─────────────────────────────────────────────────────
//
// Returns entropy in bits (>= 0), or a negative value on any CUDA error so
// the dispatcher falls back to a CPU kernel instead of reporting H = 0
// (a fake "total collapse") for a device failure.

double configurational_entropy_cuda(const double* w, std::size_t n) {
    if (n <= 1) return 0.0;

    static thread_local DeviceCache cache;
    if (!cache.ensure(n)) return -1.0;

    if (cudaMemcpy(cache.d_w, w, n * sizeof(double),
                   cudaMemcpyHostToDevice) != cudaSuccess) {
        return -1.0;
    }

    configurational_entropy_kernel<<<1, kBlockThreads>>>(cache.d_w, n, cache.d_result);
    if (cudaGetLastError() != cudaSuccess) return -1.0;

    double h_result = 0.0;
    // cudaMemcpy on the default stream synchronizes with the kernel.
    if (cudaMemcpy(&h_result, cache.d_result, sizeof(double),
                   cudaMemcpyDeviceToHost) != cudaSuccess) {
        return -1.0;
    }
    return h_result;
}

}  // namespace shannon::kernels::cuda

#endif  // SHANNON_USE_CUDA
