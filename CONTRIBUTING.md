# Contributing to Shannon

Thank you for your interest in contributing. This guide covers build, test, and code style requirements.

## Prerequisites

- C++20 compiler (GCC >= 10, Clang >= 10, MSVC 2019+)
- CMake >= 3.16
- Python >= 3.10 (for bindings and Python tests)
- Optional: OpenMP, Eigen3, CUDA Toolkit, Metal framework

## Quick Start

```bash
git clone https://github.com/lmorency/Shannon.git
cd Shannon

# Build C++ library + tests + agent
cmake -B build -DSHANNON_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure

# Python development
pip install -e ".[dev]"
pytest tests/python/ -v
```

## Development Workflow

1. Create a feature branch from `main`
2. Make changes with tests
3. Verify all tests pass: `ctest --test-dir build && pytest tests/python/`
4. Run linter: `ruff check python/ tests/`
5. Open a pull request

## Code Style

### C++

- C++20 standard
- No GPL/AGPL dependencies (Apache-2.0, BSD, MIT, MPL-2.0 only)
- `[[nodiscard]]` on all functions returning a value the caller must use
- `noexcept` on pure numerical compute functions with no heap allocation or I/O
- `std::atomic` for shared counters; `std::mutex` for non-trivial shared state
- `std::fmax` (not `std::max`) for NaN-safe floating-point clamping
- Two-pass variance for sliding window statistics (never `E[X^2] - (E[X]^2`)
- Use `memcpy` for type-punning (never `reinterpret_cast` on references)
- Per-ISA SIMD files get their own `.cpp` compiled with targeted `-m` flags
- No comments unless explicitly requested

### Python

- Python >= 3.9
- Follow existing patterns in `shannon_entropy/`
- `ruff check` and `ruff format` must pass

## Adding a New C++ Source File

1. Add `.cpp` / `.h` files under `src/shannon/`
2. Add the source to the appropriate list in `CMakeLists.txt`
3. Add `#include` guards matching existing conventions
4. Write tests in `tests/cpp/test_shannon_v2.cpp` using GoogleTest
5. Rebuild and verify: `cmake --build build -j && ctest --test-dir build`

## Adding a New Entropy Kernel

1. Create `entropy_<backend>.cpp` under `src/shannon/`
2. Declare in `src/shannon/entropy.hpp` with `[[nodiscard]] noexcept`
3. Add a `case Backend::<NAME>:` block in `unified_dispatch.cpp` (all three switch statements)
4. Add per-file ISA compilation flags in `CMakeLists.txt`
5. Add `[[fallthrough]];` after the `#endif` guard

## Testing Requirements

All changes must pass:

```bash
# C++ tests (70 tests)
cmake --build build -j
ctest --test-dir build --output-on-failure

# Python tests
pytest tests/python/ -v

# Lint
ruff check python/ tests/
```

## Commit Messages

Use prefix: `Fix:`, `Add:`, `Update:`, `Refactor:`, `Docs:`, etc.

Example: `Fix: Define missing _rel_lib variable in setup.py`

## Reporting Issues

Open an issue at https://github.com/lmorency/Shannon/issues with:
- Shannon version (`grep VERSION CMakeLists.txt`)
- Compiler and platform
- Minimal reproduction steps

## License

By contributing, you agree your code will be licensed under the MIT License.
