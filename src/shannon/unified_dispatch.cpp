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
        detected_.store(true, std::memory_order_release);
    });
}

void UnifiedDispatch::ensure_detected() const {
    // detect() is idempotent via call_once; mutable members allow const path.
    if (!detected_.load(std::memory_order_acquire)) {
        std::call_once(detect_flag_, [this] {
            hw_ = hw::detect_hardware();
            detected_.store(true, std::memory_order_release);
        });
    }
}

const hw::HardwareCapabilities& UnifiedDispatch::capabilities() const noexcept {
    ensure_detected();
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
    case Backend::AUTO:   return true;
    }
    return false;
}

bool UnifiedDispatch::has_kernel(Backend b, KernelType kernel) const noexcept {
    switch (b) {
    case Backend::SCALAR:
        return true;
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        return hw_.has_openmp;
#else
        return false;
#endif
    case Backend::SSE42:
#if defined(SHANNON_USE_SSE42) && defined(__x86_64__)
        // SSE4.2 only implements configurational_entropy
        return hw_.has_sse42 && kernel == KernelType::CONFIGURATIONAL_ENTROPY;
#else
        (void)kernel;
        return false;
#endif
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        return hw_.has_avx2;
#else
        return false;
#endif
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        return hw_.has_avx512;
#else
        return false;
#endif
    case Backend::NEON:
#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
        // Full NEON suite: configurational + probs + logprobs
        return hw_.has_neon && (
            kernel == KernelType::CONFIGURATIONAL_ENTROPY ||
            kernel == KernelType::SHANNON_ENTROPY ||
            kernel == KernelType::LOGPROB_ENTROPY);
#else
        (void)kernel;
        return false;
#endif
    case Backend::AUTO:
        return true;
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
    case Backend::AUTO:   return "AUTO";
    }
    return "UNKNOWN";
}

std::vector<Backend> UnifiedDispatch::available_backends() const {
    ensure_detected();
    static constexpr Backend kAllBackends[] = {
        Backend::SCALAR, Backend::OPENMP, Backend::SSE42, Backend::AVX2,
        Backend::AVX512, Backend::NEON
    };
    std::vector<Backend> result;
    for (Backend b : kAllBackends) {
        if (is_available(b)) result.push_back(b);
    }
    return result;
}

std::string UnifiedDispatch::hardware_report() const {
    ensure_detected();
    return hw_.summary();
}

Backend UnifiedDispatch::best_backend(KernelType kernel, std::size_t n) const {
    // Without this, calling best_backend()/hardware_report() before the first
    // compute_* reads a default-constructed (all-false) capability set and
    // reports SCALAR on a machine with AVX-512.
    ensure_detected();
    Backend ov = override_.load(std::memory_order_relaxed);
    if (ov != Backend::AUTO && is_available(ov) && has_kernel(ov, kernel)) {
        return ov;
    }

    // x86 wide SIMD
    if (has_kernel(Backend::AVX512, kernel)) return Backend::AVX512;
    if (has_kernel(Backend::AVX2, kernel))   return Backend::AVX2;

    // NEON vs OpenMP tradeoff on aarch64:
    //   - medium n: single-thread NEON wins (no fork/join tax)
    //   - large n:  multi-core OpenMP typically wins despite scalar exp
    if (n >= kOpenMpPreferThreshold && has_kernel(Backend::OPENMP, kernel)) {
        return Backend::OPENMP;
    }

    // SSE4.2 (configurational only) and full NEON suite
    if (has_kernel(Backend::SSE42, kernel)) return Backend::SSE42;
    if (has_kernel(Backend::NEON, kernel))  return Backend::NEON;

    if (has_kernel(Backend::OPENMP, kernel)) return Backend::OPENMP;

    return Backend::SCALAR;
}

// ─── Dispatched entropy functions ────────────────────────────────────────────

DispatchResult UnifiedDispatch::compute_configurational_entropy(
    const double* log_weights, std::size_t n, double& out_entropy,
    Backend backend)
{
    ensure_detected();

    DispatchResult result;
    result.used_backend = best_backend(KernelType::CONFIGURATIONAL_ENTROPY, n);
    if (backend != Backend::AUTO && is_available(backend) &&
        has_kernel(backend, KernelType::CONFIGURATIONAL_ENTROPY)) {
        result.used_backend = backend;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    // Track whether a real kernel ran; fallthrough must not leave a stale backend.
    bool ran = false;
    switch (result.used_backend) {
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        out_entropy = kernels::configurational_entropy_avx512(log_weights, n);
        result.used_backend = Backend::AVX512;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        out_entropy = kernels::configurational_entropy_avx2(log_weights, n);
        result.used_backend = Backend::AVX2;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::SSE42:
#if defined(SHANNON_USE_SSE42) && defined(__x86_64__)
        out_entropy = kernels::configurational_entropy_sse42(log_weights, n);
        result.used_backend = Backend::SSE42;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::NEON:
#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
        out_entropy = kernels::configurational_entropy_neon(log_weights, n);
        result.used_backend = Backend::NEON;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        if (hw_.has_openmp) {
            out_entropy = kernels::configurational_entropy_omp(log_weights, n);
            result.used_backend = Backend::OPENMP;
            ran = true;
            break;
        }
#endif
        [[fallthrough]];
    default:
        break;
    }

    if (!ran) {
        out_entropy = kernels::configurational_entropy_scalar(log_weights, n);
        result.used_backend = Backend::SCALAR;
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
    ensure_detected();

    DispatchResult result;
    result.used_backend = best_backend(KernelType::SHANNON_ENTROPY, n);
    if (backend != Backend::AUTO && is_available(backend) &&
        has_kernel(backend, KernelType::SHANNON_ENTROPY)) {
        result.used_backend = backend;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    bool ran = false;
    switch (result.used_backend) {
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_probs_avx512(probs, n);
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_probs_avx2(probs, n);
        result.used_backend = Backend::AVX2;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::NEON:
#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
        out_entropy = kernels::entropy_from_probs_neon(probs, n);
        result.used_backend = Backend::NEON;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        if (hw_.has_openmp) {
            out_entropy = kernels::entropy_from_probs_omp(probs, n);
            result.used_backend = Backend::OPENMP;
            ran = true;
            break;
        }
#endif
        [[fallthrough]];
    default:
        break;
    }

    if (!ran) {
        out_entropy = kernels::entropy_from_probs_scalar(probs, n);
        result.used_backend = Backend::SCALAR;
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
    ensure_detected();

    DispatchResult result;
    result.used_backend = best_backend(KernelType::LOGPROB_ENTROPY, n);
    if (backend != Backend::AUTO && is_available(backend) &&
        has_kernel(backend, KernelType::LOGPROB_ENTROPY)) {
        result.used_backend = backend;
    }

    auto t0 = std::chrono::high_resolution_clock::now();

    bool ran = false;
    switch (result.used_backend) {
    case Backend::AVX512:
#if defined(SHANNON_USE_AVX512) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_logprobs_avx512(logprobs, n);
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::AVX2:
#if defined(SHANNON_USE_AVX2) && defined(__x86_64__)
        out_entropy = kernels::entropy_from_logprobs_avx2(logprobs, n);
        result.used_backend = Backend::AVX2;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::NEON:
#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
        out_entropy = kernels::entropy_from_logprobs_neon(logprobs, n);
        result.used_backend = Backend::NEON;
        ran = true;
        break;
#endif
        [[fallthrough]];
    case Backend::OPENMP:
#if defined(SHANNON_USE_OPENMP)
        if (hw_.has_openmp) {
            out_entropy = kernels::entropy_from_logprobs_omp(logprobs, n);
            result.used_backend = Backend::OPENMP;
            ran = true;
            break;
        }
#endif
        [[fallthrough]];
    default:
        break;
    }

    if (!ran) {
        out_entropy = kernels::entropy_from_logprobs_scalar(logprobs, n);
        result.used_backend = Backend::SCALAR;
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
    ensure_detected();
    Backend sel = best_backend(KernelType::CONFIGURATIONAL_ENTROPY);
    return DispatchReport{
        .selected  = sel,
        .reason    = std::string("Best available: ") + backend_name(sel),
        .hw_summary = hw_.summary(),
    };
}

}  // namespace shannon::dispatch
