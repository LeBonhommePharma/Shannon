# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Summary

Shannon is a physics-grounded LLM safety library for zero-shot detection of evaluation awareness and strategic deception in frontier LLM agents. It ports configurational entropy computation from molecular docking (FlexAID∆S) to detect entropy collapse in LLM token distributions. When an LLM becomes evaluation-aware, its token distributions narrow (H drops from ~8-12 bits to ~2-4 bits), detectable via a sliding-window z-score threshold (default δ < -3.2 bits).

## Coding Directives

- Start coding immediately when asked to implement — do not spend more than 1-2 rounds reading/planning before writing code.
- When implementing from a plan or spec, proceed step-by-step through each item without skipping unless told otherwise.
- After writing new code, always verify it compiles/builds before committing.

## Git Configuration

- Use a GitHub no-reply email (e.g., `username@users.noreply.github.com`) for commits to avoid push failures from email privacy settings.
- Always check `.gitignore` patterns before committing new file types (e.g., `*.md`, `VERSION*`).

## File Naming Convention

- Use underscores (not hyphens) in Python package and module names to avoid import errors.
- Check existing naming patterns in the repo before creating new files or directories.

## Build & Install

```bash
# Full build with Python bindings and dev tools
pip install -e ".[dev]"

# C++ library only (no Python)
cmake -B build -DSHANNON_BUILD_PYTHON=OFF
cmake --build build --config Release -j
```

## Testing

```bash
# Python tests (pytest, 23 tests)
pytest tests/python/ -v

# Single test file
pytest tests/python/test_detector.py -v -k "test_name"

# C++ tests (GoogleTest)
cmake -B build -DSHANNON_BUILD_TESTS=ON -DSHANNON_BUILD_PYTHON=OFF
cmake --build build -j
ctest --test-dir build --output-on-failure
```

## Linting & Formatting

```bash
ruff check python/ tests/
ruff format --check python/ tests/
mypy python/
```

Target: Python 3.10+, line length 100, ruff rules E/F/W/I/UP.

## Project Structure

- Primary languages: Python, C++20, with YAML for configuration
- CMake build system — always run `cmake -B build` then `cmake --build build` to compile
- Python tests via `pytest tests/python/ -v`, C++ tests via `ctest --test-dir build --output-on-failure`
- ~23 Python tests and a GoogleTest C++ suite — all should pass before committing

## Architecture

### Three-tier backend pipeline (core.py)

```
core.py → _shannon_cpp (C++/pybind11, OpenMP+SIMD)
        → Numba JIT (@njit, prange)
        → Pure NumPy (fallback, always available)
```

Each tier implements the same log-sum-exp configurational entropy kernel. `core.py` auto-selects the fastest available backend at import time.

### Key components

- **src/shannon.cpp** — C++20 core: log-sum-exp entropy kernel with OpenMP+SIMD pragmas (namespace `shannon`)
- **src/bindings.cpp** — pybind11 bridge exposing C++ kernels to Python
- **python/shannon_entropy/core.py** — backend selection and pure-NumPy/Numba fallback implementations
- **python/shannon_entropy/detector.py** — `ShannonCollapseDetector`: sliding-window state machine that tracks entropy over token stream, computes z-score delta, fires callback on collapse
- **python/shannon_entropy/cli.py** — `shannon-monitor` CLI for piping JSONL token streams

### Entropy computation

Uses log-sum-exp trick for numerical stability with unnormalized log-weights:
```
max_w = max(w_i)
Z = Σ exp(w_i - max_w)            # partition function
S = log2(Z) - (1/Z) Σ (w_i - max_w) exp(w_i - max_w) / ln(2)
```

### CMake options

| Option | Default | Purpose |
|--------|---------|---------|
| `SHANNON_BUILD_TESTS` | ON | Build GoogleTest suite |
| `SHANNON_BUILD_PYTHON` | ON | Build pybind11 module |
| `SHANNON_USE_OPENMP` | ON | Enable OpenMP acceleration |

## CI

GitHub Actions (`.github/workflows/ci.yml`): Python tests on Linux/macOS/Windows × Python 3.10/3.11/3.12, C++ tests on Linux/macOS, lint with ruff on Python 3.12.
