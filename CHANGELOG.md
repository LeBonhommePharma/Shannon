# Changelog

All notable changes to Shannon are documented in this file.

## [2.0.0] — 2026-04-14

### Added

- **v2 modular C++20 library** — replaces monolithic v1 with per-component headers
- **`UnifiedDispatch`** — kernel-aware SIMD backend selection with `std::call_once` thread safety
- **`CollapseDetector`** — numerically stable two-pass variance, bounded trace, callbacks
- **`HandrailEngine`** — 6 configurable actions (LOG_ONLY, ALERT, THROTTLE, KILL, COREDUMP, WEBHOOK)
- **`TerminalAgent`** — full pipeline agent orchestrating ingestion + detection + handrails
- **Stream ingestion** — `StdinIngester` (JSONL), `SocketIngester` (Unix domain socket), `ShmemIngester` (zero-copy shared memory)
- **`TurboQuant`** — Lloyd-Max MSE-optimal quantization with bounded entropy monitoring
- **`HardwareCapabilities`** — runtime CPUID + XCR0 + CUDA + ROCm + Metal probe
- **Per-ISA SIMD kernels** — `entropy_sse42.cpp`, `entropy_avx2.cpp`, `entropy_avx512.cpp`, `entropy_neon.cpp`, `entropy_omp.cpp`
- **`shannon-agent` CLI** — 18 command-line flags, 3 stream modes
- **70 GoogleTest tests** across 12 test suites
- **Documentation** — `docs/theory.md`, `docs/architecture.md`, `docs/api.md`

### Fixed

- Replaced naive `E[X²] - (E[X])²` variance with stable two-pass `Σ(x - mean)²`
- Added OSXSAVE + XCR0 validation before AVX2/AVX-512 selection (prevents SIGILL)
- `fork()` + `execvp()` for webhooks (no shell interpolation / command injection)
- `std::atomic<int>` counters in `HandrailEngine` (thread-safe reads from stats thread)
- `std::mutex` on `last_action_time_` (prevents data race under concurrent `evaluate()`)
- `[[nodiscard]]` + `noexcept` on all 12 entropy kernel declarations
- `else if` logic in handrail prevents double-fire when `sustained_threshold=1`
- `std::fmax` replaces `std::max` for NaN-safe entropy clamping
- `strtod` operates on null-terminated `std::string` (not `string_view`)
- `memcpy`-based CPUID replaces `reinterpret_cast` type-punning (strict aliasing UB)
- `unsigned lo, hi` temporaries in XCR0 inline assembly (no type-punning UB)
- TurboQuant bits clamped to [1, 8] with NaN/Inf guards
- `best_backend()` now kernel-aware (SSE4.2/NEON only for configurational_entropy)
- `std::atomic<Backend> override_` in `UnifiedDispatch` (thread-safe override)
- `std::unique_ptr` replaces raw pointers for socket/shmem ingesters (no dangling pointers)
- ShmemIngester detects producer count reset
- `std::atomic<bool>` for SIGCHLD handler installation guard
- Debug normalization assertion in `entropy_from_logprobs_scalar`
- `n <= 1` guard in AVX2/AVX512 probs/logprobs (consistent with scalar)
- `[[fallthrough]]` in all 3 dispatch switch blocks
- `default:` case in terminal_agent format switch
- `[[nodiscard]]` on `DispatchResult::operator bool()`
- `DispatchTelemetry::summary()` implemented with backend name resolution
- `monitored_pid` changed from `std::string` to `std::optional<pid_t>`
- Corrected `--sustained` CLI help text (default: kill, not alert)
- Bounded entropy trace via `set_max_trace_size()`

## [1.0.0] — 2024-12-01

### Added

- Initial Shannon entropy collapse detection library
- Log-sum-exp entropy kernel with OpenMP acceleration
- Python bindings via pybind11 (`_shannon_cpp` module)
- Three-tier Python backend (C++ / Numba / NumPy)
- `ShannonCollapseDetector` Python class with sliding window and callbacks
- `shannon-monitor` CLI for JSONL stream monitoring
- 16 GoogleTest tests
- 23 Python pytest tests
- `docs/theory.md` mathematical foundations
- CI pipeline (Linux / macOS / Windows)
