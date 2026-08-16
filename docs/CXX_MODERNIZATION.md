# C++20 → C++26 modernization plan

Status: **Phase A complete. Phase B complete (ENH-036). Phase C + dialect 26
(ENH-037) in this tree.** CMake/`setup.py` default `-std=c++26` with a
configure-time fallback to 23 if the compiler rejects 26 (g++-13, older Apple
Clang). Portable SIMD kernel uses Parallelism TS `std::experimental::simd`
(Horner `exp`/`log2`, not scalar-per-lane). P1928 `<simd>` / `[simd.math]` /
contracts / reflection / `#embed` remain **unavailable on g++-14**.
Audience: follow-up implementers. Claim one ENH item at a time from
`docs/ENHANCEMENT_BACKLOG.md` (`ENH-033` onward).

Shannon’s C++ core defaults to **C++26** (`CMakeLists.txt`
`SHANNON_CXX_STANDARD` default 26, `setup.py` `-std=c++26` / `/std:c++26`).
Compilers that do not accept that flag fall back to C++23. The v2 kernels
still compile as C++20-compatible source (`-DSHANNON_CXX_STANDARD=20`).
Do **not** advertise C++26 in README badges until Linux **and** macOS CI
both compile `-std=c++26` without falling back.

## What we measured (2026-08-16)

| Toolchain | Flag | Result |
|---|---|---|
| Pre-ENH-036 CI Linux (`g++-13`) | `-std=c++20` | Production dialect before Phase B |
| same | `-std=c++23` | Compiles. libstdc++ **has** `std::expected`, `std::move_only_function`, `std::unreachable`, `std::to_underlying`, `std::byteswap`, `std::format`. **Missing:** `std::print`, `std::mdspan`, `std::flat_map`, `std::generator`, `std::simd`, pack indexing, contracts, reflection |
| same | `-std=c++26` / `-std=c++2c` | **Unrecognized** (`g++-13: error: unrecognized command-line option`) |
| CI Linux after ENH-036 (`g++-14`) | `-std=c++23` (default then) | Production dialect before ENH-037 |
| This image `g++-14` 14.2.0 | `-std=c++26` | Flag accepted. `__cplusplus=202400L`. **Has:** `<print>`, `expected`, placeholder `_`, `[[assume]]`. **Missing:** `<simd>` (`__cpp_lib_simd`), `<mdspan>`, `#embed`, contracts, reflection, pack indexing, `function_ref`. **Has** `<experimental/simd>` (Parallelism TS; `native_simd<double>` width 4 with `-mavx2`) |
| This image `clang++` 18.1.3 | `-std=c++26` | Flag accepted; standard library headers not wired for a libc++ C++26 build here |
| CI macOS | Apple Clang from Xcode (unpinned) | CMake falls back to C++23 if `-std=c++26` is rejected |
| CI Windows | C++ core **not built** (`SHANNON_SKIP_CORE=1`) | Dialect bump must not assume MSVC C++26 |

`std::simd` (P1928) is the only C++26 feature that would structurally
replace Shannon’s hand-written ISA kernels. As of 2026 it is landing in
**GCC 16 libstdc++**, x86-first, and **`[simd.math]` (`exp`/`log2`) is
explicitly not implemented**. Shannon’s entropy kernels spend ~95% of
runtime in a **custom vectorized `exp`** (`src/shannon/simd_exp.hpp`)
precisely because scalar `std::exp` per lane was the bottleneck. A naive
`std::simd<double>` rewrite that called scalar `exp` per lane would
regress throughput back to the ~92 M elem/s the custom kernel was
written to beat.

## Non-negotiable constraints

1. **Python twin parity.** `CollapseDetector` and
   `python/shannon/detector.py` must stay byte-identical for the same
   stream (`TestBackendParityFuzz`). Language upgrades must not change
   Welford order, sample variance (`n-1`), or event-history chronology.
2. **Stable `Backend` enumerants.** `SCALAR=0` … `NEON=5`, `AUTO=255`
   are frozen. `STD_SIMD=6` is additive (opt-in override; not AUTO).
3. **Fat-binary / SIGILL policy.** Each ISA kernel lives in its own TU
   with targeted `-m` flags (`CMakeLists.txt`). Hosted CI already
   filters AVX-512 tests (`-E 'Avx512|SimdLog2Avx2.MaxRelativeError'`).
   `std::simd` does **not** remove the need for per-ISA TUs or
   function multi-versioning.
4. **Optional native core.** `setup.py` must keep compiling with a
   C++20 fallback until every supported wheel host has the new dialect.
5. **Do not replace OpenMP with `std::execution` for this kernel.**
   Per-token entropy of one distribution is latency-bound; OpenMP
   `parallel for simd reduction` on large `n` (`entropy_omp.cpp`,
   threshold 16384 in `unified_dispatch.hpp`) is the right tool.
   P2300 senders are a pipeline abstraction, not a reduction engine.

## Current C++20 surface (keep)

Already in use, leave alone unless a later phase needs a touch-up:

- `std::span` overloads next to pointer+size APIs (`shannon.hpp`, detector, dispatch)
- `std::optional`, `std::string_view`, `std::filesystem`
- `enum class` backends / events / handrail actions
- `[[nodiscard]]`, `noexcept` kernels, `std::once_flag` + atomics
- `std::numbers::pi` in the energy matrix
- Per-ISA TUs + runtime `HardwareCapabilities` dispatch

## Gaps that actually hurt

| Gap | Where | Why it matters |
|---|---|---|
| Kernel ABI is still `const double*, size_t` as primary | `entropy.hpp`, all `entropy_*.cpp` | Null+`n>0` is UB (`docs/AUDIT_code_quality_96h.md`); span is already the documented “modern” overload |
| Four copies of the same log-sum-exp | `entropy_scalar.cpp`, `_omp`, `_avx2`, `_avx512`, `_neon`, `_sse42` | Bug-fix fan-out; blocks a future `std::simd` kernel |
| Four copies of vectorized `exp`/`log2` | `simd_exp.hpp`, `simd_log2.hpp` | Same algorithm, ISA-typed; should be a traits template *before* C++26 |
| `DispatchResult` out-param + `bool` conversion | `types.hpp`, `unified_dispatch.cpp` | C++23 `std::expected<double, DispatchError>` is the natural shape; pybind must keep today’s tuple/object |
| Hand-written `switch (Backend)` name tables | `types.hpp`, `unified_dispatch.cpp` | C++20 `constexpr` table now; C++26 reflection later |
| Allocating `std::function` callbacks | `CollapseCallback`, `TokenCallback`, `HandrailCallback` | Hot path on every token if a callback is set; C++23 `move_only_function` / C++26 `function_ref` |
| `fprintf` CLI | `apps/shannon-agent/main.cpp` | `std::format` already exists on g++-13 C++20 |
| Dual v1 / v2 `CollapseDetector` | `shannon.hpp` inline `v1` vs `src/shannon/collapse_detector.hpp` | Bindings still expose v1; SIMD dispatch is v2. Language bump will not fix this — ABI/product work |
| Runtime search for `soft_contact_256.bin` | `energy_matrix.cpp` | C++26 `#embed` can bake the 256 KB blob; C++20 can `std::to_array` of search paths today |

## Phased plan (safest first)

Each phase was a separate PR through Phase B. ENH-037 combines the C++26
dialect default with the portable SIMD kernel because that is what was
left after ENH-036; CMake still falls back to 23 if `-std=c++26` is
rejected.

### Phase A — C++20 cleanup (no dialect change)  ← **done**

Compiler at the time: **g++-13 / current Apple Clang**. Risk: low if tests stay green.

1. **Span-primary kernel ABI.** Make `std::span<const double>` the
   declared API in `entropy.hpp`; keep `const double*, size_t` as
   `inline` wrappers that build a span (reject `nullptr && n > 0`).
2. **ISA traits + one algorithm.** Introduce
   `src/shannon/entropy_algorithm.hpp` with the log-sum-exp / H(p) /
   H(logp) loops parameterized by a vector traits type
   (`width`, `load`, `add`, `fmadd`, `hsum`, `exp`, `log2`, `max`,
   `mask_gt`). Existing AVX2/AVX-512/NEON/SSE files become thin
   traits + a one-line call. Scalar/OpenMP stay as the `width=1`
   / reduction specializations.
3. **`constexpr` backend name table** replacing the switches in
   `DispatchTelemetry::summary` and `backend_name`. Add a
   `default: std::abort()` (C++23: `std::unreachable()`) so a new
   enumerant fails closed.
4. **`std::format` for telemetry / agent log lines** that today
   concatenate `std::to_string`. Do not restyle help text in the
   same PR.
5. **Null / empty guards** on public kernels (audit item). GoogleTest
   coverage in `tests/cpp/test_shannon_v2.cpp`.

Acceptance: `ctest` 94/94 with the CI AVX filter; Python
`TestBackendParityFuzz` unchanged; `shannon._HAS_CORE` still `True`
on this image.

### Phase B — compiler bump, then C++23

**First slice done (ENH-036):** Ubuntu `cpp` / `python` / `benchmarks` jobs
install **g++-14** (not 13); macOS stays unpinned Apple Clang; Windows still
`SHANNON_SKIP_CORE=1`. CMake `SHANNON_CXX_STANDARD` defaults to 23;
`setup.py` `_cxx_std_args` emits `-std=c++23` / `/std:c++23` (env
`SHANNON_CXX_STANDARD=20` is the packager hatch). Kernels were **not**
rewritten in that PR.

**Second slice done:** C++23 library façade behind feature-test macros so the
C++20 hatch still compiles:

1. `EntropyExpected` = `std::expected<double, DispatchError>`; `DispatchResult::as_expected` / `from_expected`; span overloads on `UnifiedDispatch`.
2. `shannon::assume_unreachable()` (`std::unreachable` / `std::abort` hatch) exists for compiler-proven dead arms only. Public `HandrailAction` / `InputFormat` / `StreamMode` switches fail closed on corrupt storage (skip token / no-op / exit 1). `backend_name(99)` still returns `"UNKNOWN"` (not UB).
3. `shannon::enum_code` (`std::to_underlying` / `static_cast` hatch) at the pybind `used_backend` boundary and handrail logs.
4. `CollapseCallback` / `HandrailCallback` / `TokenCallback` are `std::move_only_function` on C++23; `std::function` on the C++20 hatch. v1 `shannon.hpp` stays `std::function`.
5. `std::print` / `std::println` for agent/handrail log lines when `__cpp_lib_print` (g++-14+); fprintf otherwise (g++-13 Cloud snapshot).

Do **not** enable C++ modules (`import std`) in this phase — pybind11
+ FetchContent GoogleTest + per-ISA TUs are a modules foot-gun.

### Phase C — `std::simd` traits  ← **done (experimental stand-in)**

This is a **traits swap**, not a seventh copy of the algorithm (Phase A).

1. Keep custom `shannon_exp` / `shannon_log2`. C++26 `[simd.math]` is
   not available in GCC 16’s `std::simd`. Re-expressing the Horner
   polynomial on a generic SIMD type is the end state; calling
   `std::exp` per lane is a regression.
2. **Done:** `src/shannon/simd_generic.hpp` + `entropy_std_simd.cpp`
   instantiate `entropy_algorithm.hpp` over
   `std::experimental::native_simd<double>` (libstdc++ Parallelism TS).
   CMake `SHANNON_USE_STD_SIMD` defaults **ON**; `SHANNON_NO_STD_SIMD`
   compiles a scalar stub. x86 compiles the TU with `-mavx2 -mfma`
   (same as AVX2). `Backend::STD_SIMD = 6` is override-only —
   `best_backend()` still prefers AVX-512 / AVX2.
3. NEON: experimental simd is available on libstdc++ aarch64; Apple
   libc++ typically lacks `<experimental/simd>` (stub +
   `std_simd_kernels_built()==false`).
4. Golden tests: `StdSimdKernels.*` vs scalar; `SimdExpGeneric` /
   `SimdLog2Generic` vs libm (1e-13 / 1e-12). Never claim bit-identical
   `exp` across ISAs.
5. P1928 `<simd>` (`__cpp_lib_simd`) is still **undefined** on g++-14.
   When GCC 16 CI exists, retarget `abi::native` without changing Horner.

### Phase D — other C++26, opportunistic  ← **partial (what g++-14 has)**

| Feature | Shannon use | Status on g++-14 `-std=c++26` |
|---|---|---|
| Dialect `-std=c++26` | CMake/setup.py default | **Done** (fallback to 23) |
| `[[assume]]` | `SHANNON_ASSUME` after kernel early-outs | **Done** (`!(Z > 0)` before assume so NaN is not UB) |
| Placeholder `_` | Available; not forced through existing code | Macro reported in `cxx26.hpp` |
| `std::function_ref` | `TokenCallback` / ingest | **Blocked** |
| Contracts (`pre` / `post`) | `entropy >= 0`, non-null kernels | **Blocked** |
| `#embed` | `data/soft_contact_256.bin` | **Blocked** (path search stays) |
| Static reflection | `enum_name(Backend)` | **Blocked** (constexpr table is enough) |
| Pack indexing | Kernel dispatcher templates | **Blocked** |
| `std::mdspan` | energy matrix | **Blocked** |
| `std::inplace_vector` | Not a fit (vocab 32k–128k) | Skip |
| `std::execution` | Not a fit for this reduction | Skip |

## Suggested PR order (conflict-minimizing)

Same rule as merging peer branches: **smallest, least-overlapping
surface first**.

1. This document + backlog ids (no code).
2. Phase A.3 constexpr name table (touches `types.hpp` /
   `unified_dispatch.cpp` only).
3. Phase A.1 span-primary ABI + null guards (headers + tests).
4. Phase A.2 algorithm traits (all `entropy_*.cpp` + `simd_exp.hpp`).
   This is the conflict magnet — do it **alone**.
5. Phase A.4 `std::format` telemetry.
6. Phase B compiler bump (workflow + CMake + setup.py only).  ← **done (PR #16)**
7. Phase B `std::expected` façade.  ← **done (PR #17)**
8. Phase C portable SIMD traits + C++26 dialect default.  ← **this PR**
9. P1928 `<simd>` retarget when `__cpp_lib_simd` exists on CI.

## Explicit non-goals

- Rewriting the hand-rolled JSONL parser in `stream_ingest.cpp` as
  part of a language bump.
- Collapsing v1 `shannon_core` and v2 `shannon_v2` in the same PR as
  a dialect change.
- GPU backends (already removed; workload is transfer-bound).
- Changing the −3.2 bit threshold, Welford formula, or Python detector
  arithmetic “because C++26”.
- Advertising C++26 in README badges until Linux **and** macOS CI compile
  `-std=c++26` without the CMake fallback.

## Verification bar (every code PR)

```bash
# Linux / this environment (CI pins g++-14; g++-13 still compiles -std=c++23)
cmake -B build -DSHANNON_BUILD_TESTS=ON -DSHANNON_BUILD_PYTHON=OFF \
      -DCMAKE_CXX_COMPILER=g++-14
# Default SHANNON_CXX_STANDARD=26 (g++-14 accepts it; g++-13 falls back to 23)
cmake --build build -j
ctest --test-dir build --output-on-failure \
      -E 'Avx512|SimdLog2Avx2.MaxRelativeError'

source .venv/bin/activate
pytest tests/python/ tests/test_detector.py tests/test_train.py -q
# Expect TestBackendParityFuzz to stay in the passing set
```

Hello-world (must still flag collapse):

```bash
shannon-monitor stdin --format text < stream.jsonl
./build/shannon-agent --field logprobs --logprobs < stream.jsonl
```
