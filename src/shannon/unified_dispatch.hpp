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

#include <chrono>
#include <cstddef>
#include <cstdint>
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

    // Backend selection
    Backend best_backend(KernelType kernel = KernelType::CONFIGURATIONAL_ENTROPY) const;
    void set_override(Backend b) noexcept;
    void clear_override() noexcept;
    Backend current_override() const noexcept;

    bool is_available(Backend b) const noexcept;
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

    hw::HardwareCapabilities hw_;
    bool detected_ = false;
    Backend override_ = Backend::AUTO;

    Backend select_backend_for_entropy() const;
};

}  // namespace shannon::dispatch
