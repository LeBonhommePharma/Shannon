# C++20 → C++26 modernization plan

Status: **Phase A–D complete. ENH-040 toolchain done. ENH-041 detector
names unified** (`shannon::CollapseDetector` is v2; `shannon::v1` keeps
population variance). Next library work that still cannot compile is P1928
`std::simd::vec`: the GCC 16.0 PPA snapshot does **not** define
`__cpp_lib_simd`.

CMake 3.28 still injects `-std=c++26` because its dialect table stays 23 —
that is not a compiler fallback. README advertises C++26 when Linux **and**
macOS `cpp` jobs grep `Shannon C++ standard: 26`.

Portable SIMD prefers `std::simd::vec<T>` when `__cpp_lib_simd`; otherwise
Parallelism TS `native_simd` (g++-14, and the current GCC 16.0 PPA). Horner
`exp`/`log2` is unchanged. Phase D features are wired behind feature-test
macros: no-op on g++-14 except placeholder `_` and the constexpr soft-contact
search path / `load_from_memory`; live on GCC 16.0 for `function_ref` /
`mdspan` / pack indexing / `#embed`.
Audience: follow-up implementers. Claim one ENH item at a time from
`docs/ENHANCEMENT_BACKLOG.md` (`ENH-033` onward).

Shannon’s C++ core defaults to **C++26** (`CMakeLists.txt`
`SHANNON_CXX_STANDARD` default 26, `setup.py` `-std=c++26` / `/std:c++26`).
Compilers that do not accept that flag fall back to C++23. The v2 kernels
still compile as C++20-compatible source (`-DSHANNON_CXX_STANDARD=20`).
Do **not** advertise C++26 in README badges until Linux **and** macOS CI
both compile `-std=c++26` without the compiler falling back to 23.
**ENH-040:** both `cpp` OSes grep the configure log for
`Shannon C++ standard: 26`.

## What we measured (2026-08-16)

| Toolchain | Flag | Result |
|---|---|---|
| Pre-ENH-036 CI Linux (`g++-13`) | `-std=c++20` | Production dialect before Phase B |
| same | `-std=c++23` | Compiles. libstdc++ **has** `std::expected`, `std::move_only_function`, `std::unreachable`, `std::to_underlying`, `std::byteswap`, `std::format`. **Missing:** `std::print`, `std::mdspan`, `std::flat_map`, `std::generator`, `std::simd`, pack indexing, contracts, reflection |
| same | `-std=c++26` / `-std=c++2c` | **Unrecognized** (`g++-13: error: unrecognized command-line option`) |
| CI Linux after ENH-036 (`g++-14`) | `-std=c++23` (default then) | Production dialect before ENH-037 |
| This image `g++-14` 14.2.0 | `-std=c++26` | Flag accepted. `__cplusplus=202400L`. **Has:** `<print>`, `expected`, placeholder `_`, `[[assume]]`. **Missing:** `<simd>` (`__cpp_lib_simd`), `<mdspan>`, `#embed`, contracts, reflection, pack indexing, `function_ref`. **Has** `<experimental/simd>` (Parallelism TS; `native_simd<double>` width 4 with `-mavx2`) |
| This image `g++-16` 16.0.1 (`ppa:ubuntu-toolchain-r/test`, trunk r16-8100) | `-std=c++26` | Flag accepted. **Has:** `function_ref`, `mdspan` (`view[i, j]`), pack indexing `Ts...[I]`, `__has_embed`, placeholder `_`, `<print>`. **Missing:** `__cpp_lib_simd` / `<simd>` (P1928 hatch still dark), `__cpp_contracts`, `__cpp_impl_reflection`. **Has** `<experimental/simd>` |
| This image `clang++` 18.1.3 | `-std=c++26` | Flag accepted; standard library headers not wired for a libc++ C++26 build here |
| CI macOS | Apple Clang from Xcode (unpinned) | `cpp` job greps `Shannon C++ standard: 26`. CMake still injects `-std=c++26` (dialect table stays 23). Fallback to 23 only if the compiler rejects the flag. |
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
   filters AVX-512 tests (`-E 'Avx512|SimdLog2Avx2.MaxRelativeError|SimdExpGeneric|SimdLog2Generic'`).
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
| Dual v1 / v2 `CollapseDetector` | `shannon.hpp` `namespace v1` vs `collapse_detector.hpp` | **Done (ENH-041):** product name is v2; v1 kept as `shannon::v1` with population variance. Bindings / agent / Python twin stay on v2. |
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
3. NEON: experimental simd is available on libstdc++ aarch64. Apple
   libc++ may `__has_include` a header that is **not** the Parallelism TS
   (`native_simd` / `element_aligned`); `simd_generic.hpp` requires
   `__GLIBCXX__` + `__cpp_lib_experimental_parallel_simd`, otherwise the
   entropy TU is the scalar stub (`std_simd_kernels_built()==false`).
4. Golden tests: `StdSimdKernels.*` vs scalar; `SimdExpGeneric` /
   `SimdLog2Generic` vs libm (1e-13 / 1e-12). Never claim bit-identical
   `exp` across ISAs.
5. P1928 `<simd>` (`__cpp_lib_simd`): **done as a hatch.**
   `simd_generic.hpp` prefers `std::simd::vec<T>` (IS / GCC 16 `namespace
   std::simd`) when the macro is set, else Parallelism TS `native_simd`.
   Horner is unchanged. GCC 16 `[simd.math]` still lacks Shannon `exp`/`log2`
   (and currently fma/floor/nearbyint); those stay in this header. Do **not**
   call scalar `std::exp` per lane. `best_backend()` still ignores `STD_SIMD`.

### Phase D — other C++26, opportunistic  ← **hatched; GCC 16.0 lights some of them**

| Feature | Shannon use | g++-14 `-std=c++26` | g++-16.0 PPA |
|---|---|---|---|
| Dialect `-std=c++26` | CMake/setup.py default | **Done** (fallback to 23 if rejected) | Same |
| `[[assume]]` | `SHANNON_ASSUME` after kernel early-outs | **Done** (`!(Z > 0)` before assume so NaN is not UB) | Same |
| Placeholder `_` | Cxx26 tests | Live | Live |
| `std::function_ref` | `TokenCallbackRef` on `read_one` | Hatch (no-op) | **Live** (omit `TokenCallback&&`) |
| Contracts (`contract_assert`) | After `n > 1` kernel guards | Hatch | Still unset |
| `#embed` | `data/soft_contact_256.bin` after path search | Hatch; `load_from_memory` always | `__has_embed` live |
| Static reflection | `enum_reflect.hpp` vs `backend_name` table | Hatch; table stays UNKNOWN | Still unset |
| Pack indexing | `cxx26::nth_type_t` / `nth_value` | `tuple_element` hatch | **Live** (`Ts...[I]`) |
| `std::mdspan` | `ShannonEnergyMatrix::as_mdspan` | Hatch | **Live** |
| `std::inplace_vector` | Not a fit (vocab 32k–128k) | Skip | Skip |
| `std::execution` | Not a fit for this reduction | Skip | Skip |

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
8. Phase C portable SIMD traits + C++26 dialect default.  ← **done (PR #18)**
9. P1928 `<simd>` retarget when `__cpp_lib_simd` exists on CI.  ← **hatched (PR #20)**
10. GCC 16 hatch lane + C++26 README badge.  ← **done (ENH-040)**
11. v1/v2 detector naming unify.  ← **ENH-041 (this PR)**

**This VM:** g++-14 leaves `__cpp_lib_simd` unset (`ExperimentalTs` on
libstdc++, `Stub` on libc++). g++-16.0 from the toolchain-r PPA still leaves
`__cpp_lib_simd` unset, so P1928 `std::simd::vec` does **not** compile yet.
It **does** define `function_ref`, `mdspan`, pack indexing, and `__has_embed`.
`shannon_tests` includes `tests/test_energy_matrix.cpp`;
`gtest_discover_tests` uses `WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}` so
`data/soft_contact_256.bin` is found. `Projection.ProjectTo40x40` skips when
the singleton used the closed-form fallback.

## Explicit non-goals

- Rewriting the hand-rolled JSONL parser in `stream_ingest.cpp` as
  part of a language bump.
- Collapsing v1 `shannon_core` and v2 `shannon_v2` **libraries** in the same
  PR as a dialect change. Detector **names** are unified (ENH-041); the two
  static libs remain.
- GPU backends (already removed; workload is transfer-bound).
- Changing the −3.2 bit threshold, Welford formula, or Python detector
  arithmetic “because C++26”.
- Pinning python / release Linux jobs to experimental GCC 16.
- Claiming P1928 runs because a GCC 16 binary exists (need `__cpp_lib_simd`).

## Verification bar (every code PR)

```bash
# Proven Linux floor (CI `cpp` Ubuntu / python / release agent)
cmake -B build -DSHANNON_BUILD_TESTS=ON -DSHANNON_BUILD_PYTHON=OFF \
      -DCMAKE_CXX_COMPILER=g++-14
# Default SHANNON_CXX_STANDARD=26 (g++-14 accepts it; g++-13 falls back to 23)
cmake --build build -j
ctest --test-dir build --output-on-failure \
      -E 'Avx512|SimdLog2Avx2.MaxRelativeError|SimdExpGeneric|SimdLog2Generic'

# Hatch lane (CI `cpp-gcc16`; PPA GCC 16.0 — still no __cpp_lib_simd)
cmake -B build-gxx16 -DSHANNON_BUILD_TESTS=ON -DSHANNON_BUILD_PYTHON=OFF \
      -DCMAKE_CXX_COMPILER=g++-16
cmake --build build-gxx16 -j
ctest --test-dir build-gxx16 --output-on-failure \
      -E 'Avx512|SimdLog2Avx2.MaxRelativeError|SimdExpGeneric|SimdLog2Generic'

source .venv/bin/activate
pytest tests/python/ tests/test_detector.py tests/test_train.py -q
# Expect TestBackendParityFuzz to stay in the passing set
```

Hello-world (must still flag collapse):

```bash
shannon-monitor stdin --format text < stream.jsonl
./build/shannon-agent --field logprobs --logprobs < stream.jsonl
```
