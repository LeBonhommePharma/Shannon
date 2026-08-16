# AGENTS.md

Standard build/test/lint/run commands live in `CLAUDE.md` ("Build & Install",
"Testing", "Linting & Formatting"). Read that first; this file only records
non-obvious Cursor Cloud specifics.

## Cursor Cloud specific instructions

This repo is the **Shannon CLI** — a headless Python + C++26 library (entropy
collapse detector, `shannon`/`shannon-monitor` CLI, `shannon-agent` C++ binary,
and the `hub/` gate). There is **no web app / GUI to run here**; the macOS/iOS
"Shannon UI" lives in the separate private repo `LeBonhommePharma/ShannonUI`
and cannot be built in this environment (no Xcode/Swift on Linux).

### Python environment
- Dependencies are installed into a virtualenv at `.venv/` (the base image's
  system Python is externally-managed/PEP 668). **Activate it first**:
  `source .venv/bin/activate`, or call tools directly via `.venv/bin/python`,
  `.venv/bin/pytest`, `.venv/bin/ruff`. The `shannon` / `shannon-monitor`
  console scripts are on PATH only while the venv is active.
- The startup update script recreates `.venv`, rebuilds the editable install,
  and best-effort installs `python3-dev` (a codebase build dependency; `g++-13`
  already ships in the base image). **g++-13 does not accept `-std=c++26`**
  (CMake falls back to 23). Prefer `g++-14` when present (GitHub CI pin) so
  the default dialect is actually 26. With `python3-dev` the optional native
  C++ extension `shannon._core` **builds**, so `shannon._HAS_CORE` is `True`.
  If it ever reports `False`, the pure-NumPy fallback still works; force it
  with `SHANNON_SKIP_CORE=1`.

### Running / testing
- Python tests: `pytest tests/python/ tests/test_detector.py tests/test_train.py`.
- Hub tests need the hub tree on `PYTHONPATH`: `PYTHONPATH=hub pytest hub/tests/`.
  One test — `hub/tests/test_apple_docs_contract.py::test_test_apple_platforms_skips_without_ui_checkout`
  — shells out to `scripts/test_apple_platforms.sh`, which requires macOS
  `xcodebuild`. It **fails on Linux by design** (not a code defect) and is not
  part of CI's pytest invocation.
- C++ tests: configure with `-DCMAKE_CXX_COMPILER=g++-14` when installed
  (otherwise `g++-13`, which falls back to C++23). Default dialect is C++26
  (`-DSHANNON_CXX_STANDARD=26`); hatches are `23` and `20`. Portable SIMD
  (`Backend::STD_SIMD=6`) is an **override**, not `best_backend()` — it needs
  libstdc++ `<experimental/simd>` (present here) and, when the TU is built
  with `-mavx2`, an AVX2 host. Then run `ctest` with the CI filter
  `-E 'Avx512|SimdLog2Avx2.MaxRelativeError'` — hosted/VM CPUs may advertise
  AVX-512 in CPUID yet `SIGILL` on those paths under the hypervisor.
  C++23 library façades (`std::expected`, `move_only_function`, `std::print`)
  are feature-test guarded and drop out of the C++20 hatch.
- CMake 3.28 does **not** treat g++-14 as a `CMAKE_CXX_STANDARD 26` compiler
  (later `try_compile` for `-mavx2` fails with “dialect CXX26”). The build
  injects `-std=c++26` while leaving the CMake dialect at 23. Do not “fix”
  that by setting `CMAKE_CXX_STANDARD` to 26 on this toolchain.
- `ruff` is a **local-only** gate with known pre-existing debt (see the CI note
  in `CLAUDE.md`); it is not enforced in CI and currently reports errors.

### Hello-world (core functionality)
Pipe a JSONL token stream (`{"token": "...", "logprobs": [...]}`) through the
detector; entropy collapse fires when `dH < -3.2` bits:
`shannon-monitor stdin --format text < stream.jsonl` (Python) or
`./build/shannon-agent --field logprobs --logprobs < stream.jsonl` (C++).
