# AGENTS.md

Standard build/test/lint/run commands live in `CLAUDE.md` ("Build & Install",
"Testing", "Linting & Formatting"). Read that first; this file only records
non-obvious Cursor Cloud specifics.

## Cursor Cloud specific instructions

This repo is the **Shannon CLI** — a headless Python + C++23 library (entropy
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
  already ships in the base image and **does** compile `-std=c++23`). With both
  present the optional native C++ extension `shannon._core` **builds**, so
  `shannon._HAS_CORE` is `True`. If it ever reports `False` (e.g. `python3-dev`
  could not be installed), the pure-NumPy fallback still works; force it with
  `SHANNON_SKIP_CORE=1`. Prefer `g++-14` when present (that is the GitHub CI
  pin); do not require it on this snapshot.

### Running / testing
- Python tests: `pytest tests/python/ tests/test_detector.py tests/test_train.py`.
- Hub tests need the hub tree on `PYTHONPATH`: `PYTHONPATH=hub pytest hub/tests/`.
  One test — `hub/tests/test_apple_docs_contract.py::test_test_apple_platforms_skips_without_ui_checkout`
  — shells out to `scripts/test_apple_platforms.sh`, which requires macOS
  `xcodebuild`. It **fails on Linux by design** (not a code defect) and is not
  part of CI's pytest invocation.
- C++ tests: configure with `-DCMAKE_CXX_COMPILER=g++-13` (or `g++-14` if
  installed). Default dialect is C++23 (`-DSHANNON_CXX_STANDARD=23`); the
  packager hatch is `-DSHANNON_CXX_STANDARD=20`. C++23 library façades
  (`std::expected`, `move_only_function`, `std::print`) are feature-test
  guarded and drop out of the C++20 hatch. Then run `ctest` with the CI
  filter `-E 'Avx512|SimdLog2Avx2.MaxRelativeError'` — hosted/VM CPUs may
  advertise AVX-512 in CPUID yet `SIGILL` on those paths under the hypervisor.
- `ruff` is a **local-only** gate with known pre-existing debt (see the CI note
  in `CLAUDE.md`); it is not enforced in CI and currently reports errors.

### Hello-world (core functionality)
Pipe a JSONL token stream (`{"token": "...", "logprobs": [...]}`) through the
detector; entropy collapse fires when `dH < -3.2` bits:
`shannon-monitor stdin --format text < stream.jsonl` (Python) or
`./build/shannon-agent --field logprobs --logprobs < stream.jsonl` (C++).
