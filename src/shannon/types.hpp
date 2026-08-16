// types.hpp — Core type definitions for Shannon 2.0
//
// Pure C++20 entropy collapse detection — Le Bonhomme Pharma / NRGlab
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <version>
#if defined(__cpp_lib_expected)
#include <expected>
#endif
#include <format>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/types.h>
#endif

namespace shannon {

// C++23 std::to_underlying with a C++20 hatch (static_cast of the
// underlying type). Frozen Backend integers must stay 0–5 / 255.
template <class E>
[[nodiscard]] constexpr auto enum_code(E e) noexcept {
#if defined(__cpp_lib_to_underlying)
    return std::to_underlying(e);
#else
    return static_cast<std::underlying_type_t<E>>(e);
#endif
}

// Dead-code marker for arms the compiler can prove unreachable (closed
// switches over complete enumerations). Do **not** put this in a `default:`
// of a public enum: out-of-range storage is a valid construction and
// `std::unreachable()` is UB. Fail closed instead (`backend_name` →
// `"UNKNOWN"`, skip the token / no-op the handrail).
[[noreturn]] inline void assume_unreachable() noexcept {
#if defined(__cpp_lib_unreachable)
    std::unreachable();
#else
    std::abort();
#endif
}

// ─── Backend enumeration ─────────────────────────────────────────────────────

// GPU backends (METAL/CUDA/ROCM) were removed: this is a CPU-only, per-token
// single-distribution streaming workload. Enum values 0-5 and AUTO=255 are
// kept stable so the pybind11 binding and any persisted telemetry stay valid.
enum class Backend : uint8_t {
    SCALAR  = 0,
    OPENMP  = 1,
    SSE42   = 2,
    AVX2    = 3,
    AVX512  = 4,
    NEON    = 5,
    AUTO    = 255,
};

// Stable names for telemetry / pybind. Integer values above must not change.
// Exhaustive switch: a new enumerant fails -Wswitch. Corrupt storage yields
// "UNKNOWN" rather than UB (cannot std::abort in a constexpr path).
[[nodiscard]] constexpr const char* backend_name(Backend b) noexcept {
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

// Named backends excluding AUTO (dispatch availability / hardware reports).
inline constexpr std::array<Backend, 6> kConcreteBackends = {
    Backend::SCALAR, Backend::OPENMP, Backend::SSE42,
    Backend::AVX2, Backend::AVX512, Backend::NEON,
};

inline constexpr std::array<Backend, 7> kAllBackends = {
    Backend::SCALAR, Backend::OPENMP, Backend::SSE42,
    Backend::AVX2, Backend::AVX512, Backend::NEON, Backend::AUTO,
};

// ─── Kernel types ────────────────────────────────────────────────────────────

enum class KernelType : uint8_t {
    CONFIGURATIONAL_ENTROPY = 0,   // log-sum-exp from logits
    SHANNON_ENTROPY         = 1,   // from probabilities
    LOGPROB_ENTROPY         = 2,   // from log-probabilities
    TURBO_QUANTIZE          = 3,   // quantize logits
    TURBO_ENTROPY           = 4,   // entropy on quantized data
    COLLAPSE_DETECT         = 5,   // sliding window z-score
    KL_DIVERGENCE           = 6,   // KL(p||q) between distributions
    CROSS_ENTROPY           = 7,   // H(p, q)
    MUTUAL_INFORMATION      = 8,   // I(X_t; X_{t+1})
    JS_DIVERGENCE           = 9,   // Jensen-Shannon divergence
    EXPANSION_DETECT        = 10,  // expansion detection (symmetric to collapse)
    OSCILLATION_DETECT      = 11,  // rapid collapse/expand alternation
};

// ─── Error handling ──────────────────────────────────────────────────────────

enum class DispatchError : uint8_t {
    OK            = 0,
    NO_BACKEND    = 1,
    ALLOC_FAILED  = 2,
    LAUNCH_FAILED = 3,
    SYNC_FAILED   = 4,
    INVALID_ARGS  = 5,
    BUF_OVERFLOW  = 6,
    DEVICE_LOST   = 7,
};

#if defined(__cpp_lib_expected)
using EntropyExpected = std::expected<double, DispatchError>;
#endif

struct DispatchResult {
    DispatchError error        = DispatchError::OK;
    Backend       used_backend = Backend::AUTO;
    double        elapsed_ms   = 0.0;
    std::string   detail;

    [[nodiscard]] explicit operator bool() const { return error == DispatchError::OK; }

#if defined(__cpp_lib_expected)
    // Map this telemetry/error wrapper onto the C++23 expected façade.
    // `entropy` is the out-param from compute_*; ignored when error != OK.
    [[nodiscard]] std::expected<double, DispatchError>
    as_expected(double entropy) const noexcept {
        if (error != DispatchError::OK) {
            return std::unexpected(error);
        }
        return entropy;
    }

    static DispatchResult from_expected(const std::expected<double, DispatchError>& e,
                                        Backend used = Backend::SCALAR,
                                        double elapsed_ms = 0.0,
                                        std::string detail = {}) {
        DispatchResult r;
        r.used_backend = used;
        r.elapsed_ms = elapsed_ms;
        r.detail = std::move(detail);
        r.error = e ? DispatchError::OK : e.error();
        return r;
    }
#endif
};

// ─── Entropy event classification ────────────────────────────────────────────

enum class EntropyEvent : uint8_t {
    NONE        = 0,   // within normal bounds
    COLLAPSE    = 1,   // delta < -threshold (ordering / lock-in)
    EXPANSION   = 2,   // delta > +threshold (disordering / release)
    OSCILLATION = 3,   // rapid alternation between collapse and expansion
};

// ─── Collapse detection result ───────────────────────────────────────────────

struct CollapseResult {
    double      entropy     = 0.0;     // current token entropy (bits)
    double      window_mean = 0.0;     // mean entropy over window
    double      window_std  = 0.0;     // std-dev of entropy over window
    double      delta       = 0.0;     // entropy - window_mean (negative = collapse)
    double      z_score     = 0.0;     // standardised score (delta / std)
    bool        collapsed   = false;   // true if delta < collapse_threshold
    bool        expanded    = false;   // true if delta > expansion_threshold
    bool        oscillating = false;   // true if rapid collapse/expand alternation
    EntropyEvent event      = EntropyEvent::NONE;  // classified event
    std::size_t token_index = 0;       // 0-based token counter
    Backend     used_backend = Backend::SCALAR;  // which backend computed entropy
};

// Owned callbacks are move-only on C++23 (no type-erasure copy on the hot
// path). std::function remains the C++20 hatch alias so packagers on
// SHANNON_CXX_STANDARD=20 still compile.
#if defined(__cpp_lib_move_only_function)
using CollapseCallback = std::move_only_function<void(const CollapseResult&)>;
#else
using CollapseCallback = std::function<void(const CollapseResult&)>;
#endif

// ─── Handrail (failsafe) actions ─────────────────────────────────────────────

enum class HandrailAction : uint8_t {
    LOG_ONLY  = 0,   // write collapse event to stderr/logfile
    ALERT     = 1,   // send SIGUSR1 to monitored process
    THROTTLE  = 2,   // write throttle signal to shared memory
    KILL      = 3,   // send SIGTERM to monitored process
    COREDUMP  = 4,   // SIGABRT + capture trace
    WEBHOOK   = 5,   // HTTP POST to configured URL
    CALLBACK  = 6,   // user-defined function
};

struct HandrailConfig {
    HandrailAction on_first_collapse     = HandrailAction::ALERT;
    HandrailAction on_sustained_collapse = HandrailAction::KILL;
    HandrailAction on_expansion          = HandrailAction::ALERT;
    HandrailAction on_oscillation        = HandrailAction::ALERT;
    int            sustained_threshold   = 3;        // N consecutive collapses before escalation
    std::optional<pid_t> monitored_pid;            // PID of the LLM process
    std::string    log_path              = "/dev/stderr";
    std::string    webhook_url;                    // optional
    std::string    shmem_path;                     // optional: shared memory channel
    double         cooldown_seconds      = 5.0;       // min time between escalated actions
};

#if defined(__cpp_lib_move_only_function)
using HandrailCallback = std::move_only_function<void(HandrailAction, const CollapseResult&)>;
#else
using HandrailCallback = std::function<void(HandrailAction, const CollapseResult&)>;
#endif

// ─── Stream ingestion ────────────────────────────────────────────────────────

enum class StreamMode : uint8_t {
    STDIN_PIPE    = 0,   // JSONL on stdin
    UNIX_SOCKET   = 1,   // Unix domain socket
    SHARED_MEMORY = 2,   // POSIX shm / mmap (zero-copy)
};

enum class InputFormat : uint8_t {
    LOGITS   = 0,
    PROBS    = 1,
    LOGPROBS = 2,
};

// ─── Telemetry ───────────────────────────────────────────────────────────────

struct DispatchTelemetry {
    Backend backend           = Backend::SCALAR;
    double  wall_time_ms      = 0.0;
    int64_t elements          = 0;
    double  throughput_meps   = 0.0;   // million elements per second

    [[nodiscard]] std::string summary() const {
        return std::format(
            "DispatchTelemetry{{backend={}, wall_time_ms={}, elements={}, throughput_meps={}}}",
            backend_name(backend), wall_time_ms, elements, throughput_meps);
    }
};

struct DispatchReport {
    Backend     selected = Backend::SCALAR;
    std::string reason;
    std::string hw_summary;
};

}  // namespace shannon
