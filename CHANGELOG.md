# Changelog

All notable changes to Shannon are documented in this file.

## [Unreleased]

### Changed

- **v1/v2 CollapseDetector naming (ENH-041)** — `shannon::CollapseDetector` is
  always the v2 Welford / UnifiedDispatch detector. Legacy population-variance
  collapse-only lives in `shannon::v1` (`src/shannon.hpp`); both headers can be
  included together. `TerminalAgent` applies `AgentConfig.oscillation_window`.
  pybind `_core.CollapseDetector` default `oscillation_window` is 5 (was 16).
  Python `ShannonCollapseDetector` already passed its own window, so the twin
  path is unchanged. `shannon_core` and `shannon_v2` stay separate libraries.
- **P1928 portable SIMD retarget (ENH-038)** — `simd_generic.hpp` uses
  `std::simd::vec<T>` when `__cpp_lib_simd`; g++-14 keeps Parallelism TS
  `native_simd`. Same Horner `exp`/`log2`. `StdSimdFlavor` reports which ABI
  the TU compiled. `best_backend()` still ignores `STD_SIMD=6`.
- **GCC 16 hatch lane (ENH-040)** — Linux CI keeps **g++-14** as the proven
  floor (python / release agent / `cpp` Ubuntu). A new `cpp-gcc16` job installs
  experimental GCC 16.0 from `ppa:ubuntu-toolchain-r/test`. That snapshot
  compiles `-std=c++26` and turns on `function_ref` / `mdspan` / pack indexing /
  `#embed`; it still does **not** define `__cpp_lib_simd` (P1928 remains
  hatched). `read_one(TokenCallback&&)` is omitted when `function_ref` exists
  so lambdas are unambiguous. README advertises C++26: Linux **and** macOS `cpp`
  jobs grep the configure log for `Shannon C++ standard: 26` (compiler accepts
  the flag; CMake 3.28 still injects it because its dialect table stays 23).
- **C++23 default dialect (ENH-036)** — CMake `SHANNON_CXX_STANDARD` defaults to 23
  (`20` remains a packager hatch). Linux CI and the Linux release agent pin **g++-14**.
  `setup.py` emits `-std=c++23` / `/std:c++23` unless `SHANNON_CXX_STANDARD=20`.
- **C++23 library façade (ENH-036 remainder)** — `EntropyExpected` wraps dispatch
  entropy; `DispatchResult` stays the pybind/agent API. `enum_code` /
  `assume_unreachable` hatch to C++20 (the latter is not used on public enums).
  Callbacks are `move_only_function` on C++23. Agent/handrail log lines use
  `std::print` when `<print>` exists. Webhook POST uses curl `--url` and
  rejects non-`http(s)` URLs (curl flag injection).

### Added

- **Phase D C++26 hatches (ENH-039)** — `TokenCallbackRef` (`std::function_ref`),
  `SHANNON_CONTRACT_ASSERT`, `#embed` of `data/soft_contact_256.bin` after path
  search, `SoftContactMatrix::load_from_memory`, `nth_type_t` pack-indexing
  hatch, `ShannonEnergyMatrix::as_mdspan` on `__cpp_lib_mdspan`, P2996
  `enum_reflect.hpp` vs the fail-closed `backend_name` table. `inplace_vector`
  / `std::execution` remain skipped. `tests/test_energy_matrix.cpp` now runs
  under CMake `shannon_tests`.
- **Portable SIMD entropy kernel (ENH-037)** — Horner `exp` / atanh `log2` on
  `std::experimental::native_simd<double>` (`simd_generic.hpp`,
  `entropy_std_simd.cpp`). `Backend::STD_SIMD = 6` is an opt-in override;
  `best_backend()` still prefers AVX-512 / AVX2. P1928 `<simd>` is not in
  GCC 14; `[simd.math]` is not used. The Horner path is **libstdc++
  Parallelism TS only** (`__cpp_lib_experimental_parallel_simd`); libc++ /
  Apple compile the scalar stub. Hosted CI also filters `SimdExpGeneric` /
  `SimdLog2Generic` (AVX-512-width `native_simd` SIGILL, same class as
  `SimdLog2Avx2.MaxRelativeError`).
- **Ori-style agent harness** — `shannon grok`, `shannon claude`, `shannon codex`
  (and `opencode`, `deepseek`, `kimi`, `hermes`, `pi`, `cursor`, `prime-agent`) find the real
  CLI already on `PATH`, tag the session (`SHANNON_AGENT_ID`, task, gate socket),
  and pass remaining argv through untouched. Missing binaries print an install
  hint instead of launching a Shannon-shaped fake. `shannon` is a console-script
  alias of `shannon-monitor`; `./scripts/shannon grok` uses the same path.

## [2.1.0] — 2026-07-25

### Added

- **Claude Code ↔ Codex pair planner** — Shannon-owned half-and-half implement + cross-review via `agent_manager pair --pair-mode` (dry-run plans; skill docs under `skills/shannon/`)
- **Codex-aligned companion pets** — pure signal→motion map (`idle` / `running` / `waiting` / `failed` / `review`), 8×11 atlas frame selection, optional `~/.codex/pets` v2 package resolve with procedural Canvas fallback
- **Companion roster wiring** — pending gate asks and recent activity drive waiting/review motions; package resolve cached (no per-frame disk hits)
- **Global notify/response + multi-platform HUD sync** — OS-agnostic notify paths, shared telemetry binding, multi-agent entropy memory (prior 2.0.x mainline polish rolled into this cut)

### Fixed

- **Homebrew (macOS production path)** — hardened monorepo tap installers:
  - `Formula/shannon.rb`: correct component order, `libomp` OpenMP wiring, install hard-fail, functional JSONL collapse tests via `pipe_output`
  - `Casks/shannon-pill.rb`: Ventura+, livecheck, correct bundle zap/uninstall, Gatekeeper caveats; cask asset is a **reproducible ZIP**
  - `scripts/package_pill.sh`: SwiftPM/Xcode build, ad-hoc or Developer ID sign, optional notarization, `--install` / `--update-cask`
  - `scripts/install_macos_app.sh`: local `/Applications` install without a GitHub release
  - `scripts/update_homebrew_artifacts.sh`: post-tag formula/cask checksum helper
  - CI: `.github/workflows/homebrew.yml` (style + HEAD install + test on macOS/Linux); release workflow publishes agent tarballs + app ZIP/DMG
  - Pill packaging build fixes: `PillCore` depends on ShannonCore/Theme; `@Bindable` for `@Observable` PetStore
- **PyPI** — package version aligned to **2.1.0** for sdist + pure `py3-none-any` wheel publish

## [2.0.0] — 2026-07-16

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
- **PyPI packaging** — `setup.py` with optional `shannon._core` C++ extension and pure-Python fallback (`SHANNON_SKIP_CORE=1`); sdist + universal `py3-none-any` wheel via `.github/workflows/pypi-release.yml`
- **Homebrew formula** — `Formula/shannon.rb` installs native `shannon-agent` (OpenMP; optional `--with-metal`); monorepo tap `lebonhommepharma/shannon`
- **Release workflow** — `.github/workflows/release.yml` builds Linux/macOS `shannon-agent` artifacts on `v*` tags
- **MANIFEST.in** — ships C++ sources in sdist so out-of-tree builds can compile `_core`

### Fixed

- pybind11 module name aligned to `shannon._core` (was CMake `_shannon_cpp` vs `PYBIND11_MODULE(_core)`)
- `shannon_core` now links `energy_matrix.cpp` + `fast_optics.cpp` so the extension has no missing symbols
- Package version aligned to **2.0.0** (CMake / `python/shannon/__init__.py` / `pyproject.toml`)
- License metadata set to **Apache-2.0** (matches `LICENSE`)

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
