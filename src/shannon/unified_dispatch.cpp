// unified_dispatch.cpp — Unified hardware dispatch implementation
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/unified_dispatch.hpp"
#include "shannon/entropy.hpp"
#include "shannon/config.hpp"

#include <algorithm>
#include <sstream>

// OpenMP for threading
#ifdef _OPENMP
#  include <omp.h>
#endif

namespace shannon::dispatch {

UnifiedDispatch& UnifiedDispatch::instance() {
    static UnifiedDispatch inst;
    return inst;
}

void UnifiedDispatch::detect() {
    std::call_once(detect_flag_, [this] {
        hw_ = hw::detect_hardware();
        detected_ = true;
    });
}

const hw::HardwareCapabilities& UnifiedDispatch::capabilities() const noexcept {
    return hw_;
}

void UnifiedDispatch::set_override(Backend b) noexcept {
    override_.store(b, std::memory_order_relaxed);
}
void UnifiedDispatch::clear_override() noexcept {
    override_.store(Backend::AUTO, std::memory_order_relaxed);
}
Backend UnifiedDispatch::current_override() const noexcept {
    return override_.load(std::memory_order_relaxed);
}

bool UnifiedDispatch::is_available(Backend b) const noexcept {
    switch (b) {
    case Backend::SCALAR: return true;
    case Backend::OPENMP: return hw_.has_openmp;
    case Backend::SSE42:  return hw_.has_sse42;
    case Backend::AVX2:   return hw_.has_avx2;
    case Backend::AVX512: return hw_.has_avx512;
    case Backend::NEON:   return hw_.has_neon;
    case Backend::METAL:  return hw_.has_metal;
    case Backend::CUDA:   return hw_.has_cuda;
    case Backend::ROCM:   return hw_.has_rocm;
    case Backend::AUTO:   return true;
    }
    return false;
}

const char* UnifiedDispatch::backend_name(Backend b) noexcept {
    switch (b) {
    case Backend::SCALAR: return "SCALAR";
    case Backend::OPENMP: return "OPENMP";
    case Backend::SSE42:  return "SSE42";
    case Backend::AVX2:   return "AVX2";
    case Backend::AVX512: return "AVX512";
    case Backend::NEON:   return "NEON";
    case Backend::METAL:  return "METAL";
    case Backend::CUDA:   return "CUDA";
    case Backend::ROCM:   return "ROCM";
    case Backend::AUTO:   return "AUTO";
    }
    return "UNKNOWN";
}

std::vector<Backend> UnifiedDispatch::available_backends() const {
    static constexpr Backend kAllBackends[] = {
        Backend::SCALAR, Backend::OPENMP, Backend::SSE42, Backend::AVX2,
        Backend::AVX512, Backend::NEON, Backend::METAL, Backend::CUDA, Backend::ROCM
    };
    std::vector<Backend> result;
    for (Backend b : kAllBackends) {
        if (is_available(b)) result.push_back(b);
    }
    return result;
}

std::string UnifiedDispatch::hardware_report() const {
    return hw_.summary();
}

Backend UnifiedDispatch::select_backend_for_entropy() const {
    // GPU backends first (if available and kernel supports it)
    if (hw_.has_cuda)  return Backend::CUDA;
    if (hw_.has_rocm)  return Backend::ROCM;
    if (hw_.has_metal) return Backend::METAL;

    // CPU SIMD hierarchy
    if (hw_.has_avx512) return Backend::AVX512;
    if (hw_.has_avx2)   return Backend::AVX2;
    if (hw_.has_sse42)  return Backend::SSE42;
    if (hw_.has_neon)   return Backend::NEON;
    if (hw_.has_openmp) return Backend::OPENMP;

    return Backend::SCALAR;
}

Backend UnifiedDispatch::best_backend(KernelType kernel) const {
    Backend ov = override_.load(std::memory_order_relaxed);
    if (ov != Backend::AUTO && is_available(ov)) {
        return ov;
    }

    if (hw_.has_cuda)  return Backend::CUDA;
    if (hw_.has_rocm)  return Backend::ROCM;
    if (hw_.has_metal) return Backend::METAL;

    if (hw_.has_avx512) return Backend::AVX512;
    if (hw_.has_avx2)   return Backend::AVX2;

    if (kernel == KernelType::CONFIGURATIONAL_ENTROPY) {
        if (hw_.has_sse42)  return Backend::SSE42;
        if (hw_.has_neon)   return Backend::NEON;
    }

    if (hw_.has_openmp) return Backend::OPENMP;

    return Backend::SCALAR;
}

// ─── Dispatched entropy functions ────────────────────────────────────────────

DispatchResult UnifiedDispatch::compute_configurational_entropy(
    const double* log_weights, std::size_t n, double& out_entropy,
    Backend backend)
{
    if (!detected_) detect();

    DispatchResult result;
    result.used_backend = best_backend(KernelType::CONFIGURATIONAL_ENTROPY);
    if (backend != Backend::AUTO && is_available(backend)) {
        result.used_backend = backend;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    switch (result.used_backend) {
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        out_entropy = kernels::configurational_entropy_avx512(log_weights, n);
        break;
#endif
        [[fallthrough]];
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        out_entropy = kernels::configurational_entropy_avx2(log_weights, n);
        break;
#endif
        [[fallthrough]];
    case Backend::SSE42:
#if defined(SHANNON_USE_SSE42) && defined(__x86_64__)
        out_entropy = kernels::configurational_entropy_sse42(log_weights, n);
        break;
#endif
        [[fallthrough]];
    case Backend::NEON:
#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
        out_entropy = kernels::configurational_entropy_neon(log_weights, n);
        break;
#endif
        [[fallthrough]];
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        out_entropy = kernels::configurational_entropy_omp(log_weights, n);
        break;
#endif
        // Fall through to scalar
    default:
        out_entropy = kernels::configurational_entropy_scalar(log_weights, n);
        result.used_backend = Backend::SCALAR;
        break;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    result.elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    result.error = DispatchError::OK;
    return result;
}

DispatchResult UnifiedDispatch::compute_entropy_from_probs(
    const double* probs, std::size_t n, double& out_entropy,
    Backend backend)
{
    if (!detected_) detect();

    DispatchResult result;
    result.used_backend = best_backend(KernelType::SHANNON_ENTROPY);
    if (backend != Backend::AUTO && is_available(backend)) {
        result.used_backend = backend;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    switch (result.used_backend) {
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_probs_avx512(probs, n);
        break;
#endif
        [[fallthrough]];
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_probs_avx2(probs, n);
        break;
#endif
        [[fallthrough]];
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        out_entropy = kernels::entropy_from_probs_omp(probs, n);
        break;
#endif
        [[fallthrough]];
    default:
        out_entropy = kernels::entropy_from_probs_scalar(probs, n);
        result.used_backend = Backend::SCALAR;
        break;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    result.elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    result.error = DispatchError::OK;
    return result;
}

DispatchResult UnifiedDispatch::compute_entropy_from_logprobs(
    const double* logprobs, std::size_t n, double& out_entropy,
    Backend backend)
{
    if (!detected_) detect();

    DispatchResult result;
    result.used_backend = best_backend(KernelType::LOGPROB_ENTROPY);
    if (backend != Backend::AUTO && is_available(backend)) {
        result.used_backend = backend;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    switch (result.used_backend) {
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_logprobs_avx512(logprobs, n);
        break;
#endif
        [[fallthrough]];
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_logprobs_avx2(logprobs, n);
        break;
#endif
        [[fallthrough]];
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        out_entropy = kernels::entropy_from_logprobs_omp(logprobs, n);
        break;
#endif
        [[fallthrough]];
    default:
        out_entropy = kernels::entropy_from_logprobs_scalar(logprobs, n);
        result.used_backend = Backend::SCALAR;
        break;
    }

    auto t1 = std::chrono::high_resolution_clock::now();
    result.elapsed_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    result.error = DispatchError::OK;
    return result;
}

DispatchResult UnifiedDispatch::compute_configurational_entropy(
    std::span<const double> log_weights, double& out_entropy,
    Backend backend)
{
    return compute_configurational_entropy(
        log_weights.data(), log_weights.size(), out_entropy, backend);
}

DispatchReport UnifiedDispatch::get_dispatch_report() const {
    Backend sel = best_backend(KernelType::CONFIGURATIONAL_ENTROPY);
    return DispatchReport{
        .selected  = sel,
        .reason    = std::string("Best available: ") + backend_name(sel),
        .hw_summary = hw_.summary(),
    };
}

}  // namespace shannon::dispatch
