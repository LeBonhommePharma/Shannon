// unified_dispatch.hpp — Meyers singleton hardware dispatch for Shannon 2.0
//
// Ported from FlexAIDdS UnifiedHardwareDispatch.h into shannon::dispatch.
// Single entry point that detects hardware, selects best backend per kernel,
// and dispatches to the optimal implementation (AVX-512, AVX2, SSE4.2, NEON,
// OpenMP, CUDA, ROCm, Metal, or scalar).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/hardware_detect.hpp"
#include "shannon/types.hpp"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <span>
#include <string>
#include <vector>

namespace shannon::dispatch {

class UnifiedDispatch {
public:
    // Meyers singleton
    static UnifiedDispatch& instance();

    // Hardware detection (idempotent, thread-safe)
    void detect();
    const hw::HardwareCapabilities& capabilities() const noexcept;

    // Backend selection.
    // Optional n enables size-aware tradeoffs (e.g. NEON vs multi-core OpenMP
    // for large vocabularies on aarch64).
    Backend best_backend(KernelType kernel = KernelType::CONFIGURATIONAL_ENTROPY,
                         std::size_t n = 0) const;
    void set_override(Backend b) noexcept;
    void clear_override() noexcept;
    Backend current_override() const noexcept;

    bool is_available(Backend b) const noexcept;
    /// True when a backend has a compiled kernel for this entry point.
    bool has_kernel(Backend b, KernelType kernel) const noexcept;
    static const char* backend_name(Backend b) noexcept;
    std::vector<Backend> available_backends() const;
    std::string hardware_report() const;

    // ─── Dispatched entropy compute functions ────────────────────────────────

    // Main entry: configurational entropy from logits (log-sum-exp)
    DispatchResult compute_configurational_entropy(
        const double* log_weights, std::size_t n, double& out_entropy,
        Backend backend = Backend::AUTO);

    // Shannon entropy from probability distribution
    DispatchResult compute_entropy_from_probs(
        const double* probs, std::size_t n, double& out_entropy,
        Backend backend = Backend::AUTO);

    // Shannon entropy from log-probabilities
    DispatchResult compute_entropy_from_logprobs(
        const double* logprobs, std::size_t n, double& out_entropy,
        Backend backend = Backend::AUTO);

    // Convenience: vector overloads
    DispatchResult compute_configurational_entropy(
        std::span<const double> log_weights, double& out_entropy,
        Backend backend = Backend::AUTO);

    // Dispatch report for debugging
    DispatchReport get_dispatch_report() const;

private:
    UnifiedDispatch() = default;

    // OpenMP fork/join beats single-thread NEON (2-wide doubles) only for large n.
    static constexpr std::size_t kOpenMpPreferThreshold = 16384;

    // Mutable so ensure_detected() can run from const accessors.
    mutable hw::HardwareCapabilities hw_;
    mutable std::once_flag detect_flag_;
    mutable std::atomic<bool> detected_{false};
    std::atomic<Backend> override_{Backend::AUTO};

    void ensure_detected() const;
};

}  // namespace shannon::dispatch
