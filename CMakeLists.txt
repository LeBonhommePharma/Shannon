cmake_minimum_required(VERSION 3.16)
project(shannon VERSION 2.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# ── Options ──────────────────────────────────────────────────────────────────────
option(SHANNON_BUILD_TESTS    "Build GoogleTest unit tests"     ON)
option(SHANNON_BUILD_PYTHON   "Build pybind11 Python module"    ON)
option(SHANNON_BUILD_AGENT    "Build shannon-agent CLI"         ON)
option(SHANNON_USE_OPENMP     "Enable OpenMP acceleration"      ON)
option(SHANNON_USE_EIGEN      "Enable Eigen vectorization"      OFF)
# GPU backends (CUDA/Metal/ROCm) were removed in this release: the workload is
# per-token streaming entropy of a single distribution, which is latency- and
# transfer-bound on a discrete GPU (H2D of up to ~1 MB + launch overhead per
# token) with no in-repo batched/on-device-resident use case to amortise it.
# See the commit message for the full removal rationale.

# ── Version from CMake ──────────────────────────────────────────────────────────
configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/src/shannon/config.hpp.in
    ${CMAKE_CURRENT_BINARY_DIR}/generated/shannon/config.hpp
    @ONLY
)

# ── v2 Core library (shannon::dispatch + kernels + detector + handrail) ───────

# Base sources — no ISA-specific code, compiled at baseline ISA
set(SHANNON_V2_BASE_SOURCES
    src/shannon/entropy_scalar.cpp
    src/shannon/hardware_detect.cpp
    src/shannon/unified_dispatch.cpp
    src/shannon/collapse_detector.cpp
    src/shannon/handrail.cpp
    src/shannon/turbo_quant.cpp
    src/shannon/stream_ingest.cpp
    src/shannon/terminal_agent.cpp
)

# Per-ISA sources — each compiled with its own flags
set(SHANNON_SIMD_SOURCES)

# Compile definitions for conditional compilation
set(SHANNON_DEFS)
if(SHANNON_USE_OPENMP)
    list(APPEND SHANNON_DEFS SHANNON_USE_OPENMP)
endif()
if(SHANNON_USE_EIGEN)
    list(APPEND SHANNON_DEFS SHANNON_USE_EIGEN)
endif()

# ── Per-ISA SIMD detection and source selection ────────────────────────────────
# Each ISA variant lives in its own .cpp file compiled with targeted -m flags.
# The rest of the library compiles at baseline ISA — no SIGILL on lesser CPUs.

include(CheckCXXCompilerFlag)

if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    check_cxx_compiler_flag("-mavx512f" SHANNON_COMPILER_AVX512)
    check_cxx_compiler_flag("-mavx2"    SHANNON_COMPILER_AVX2)
    check_cxx_compiler_flag("-msse4.2"  SHANNON_COMPILER_SSE42)

    # OpenMP (no special ISA flags needed)
    list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_omp.cpp)

    # SSE4.2 — compiled with -msse4.2
    if(SHANNON_COMPILER_SSE42)
        list(APPEND SHANNON_DEFS SHANNON_USE_SSE42 SHANNON_HAS_SSE42)
        list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_sse42.cpp)
    endif()

    # AVX2 — compiled with -mavx2 -mfma
    if(SHANNON_COMPILER_AVX2)
        list(APPEND SHANNON_DEFS SHANNON_USE_AVX2 SHANNON_HAS_AVX2)
        list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_avx2.cpp)
    endif()

    # AVX-512 — compiled with -mavx512f -mavx512dq -mavx512bw
    if(SHANNON_COMPILER_AVX512)
        list(APPEND SHANNON_DEFS SHANNON_USE_AVX512 SHANNON_HAS_AVX512)
        list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_avx512.cpp)
    endif()

elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64|armv8")
    # NEON/ASIMD is mandatory on AArch64 — always build the NEON kernels.
    list(APPEND SHANNON_DEFS SHANNON_USE_NEON SHANNON_HAS_NEON)
    list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_omp.cpp)
    list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_neon.cpp)
    message(STATUS "Shannon: ARM NEON/ASIMD entropy kernels enabled")
else()
    list(APPEND SHANNON_SIMD_SOURCES src/shannon/entropy_omp.cpp)
endif()

# OpenMP HAS_ alias only when the toolchain actually provides OpenMP
if(SHANNON_USE_OPENMP)
    find_package(OpenMP)
    if(OpenMP_CXX_FOUND)
        list(APPEND SHANNON_DEFS SHANNON_HAS_OPENMP)
    endif()
endif()

# ── Build the v2 library ───────────────────────────────────────────────────────

add_library(shannon_v2 STATIC
    ${SHANNON_V2_BASE_SOURCES}
    ${SHANNON_SIMD_SOURCES}
)
target_include_directories(shannon_v2 PUBLIC
    src/
    ${CMAKE_CURRENT_BINARY_DIR}/generated/
)
target_compile_definitions(shannon_v2 PUBLIC ${SHANNON_DEFS})

# Per-file ISA flags — only for SIMD kernels, not the whole library
if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
    set_source_files_properties(src/shannon/entropy_sse42.cpp PROPERTIES COMPILE_FLAGS "-msse4.2")
    if(SHANNON_COMPILER_AVX2)
        set_source_files_properties(src/shannon/entropy_avx2.cpp PROPERTIES COMPILE_FLAGS "-mavx2 -mfma")
    endif()
    if(SHANNON_COMPILER_AVX512)
        set_source_files_properties(src/shannon/entropy_avx512.cpp PROPERTIES COMPILE_FLAGS "-mavx512f -mavx512dq -mavx512bw -mfma")
    endif()
endif()

target_link_libraries(shannon_v2 PUBLIC)

if(SHANNON_USE_OPENMP AND OpenMP_CXX_FOUND)
    target_link_libraries(shannon_v2 PUBLIC OpenMP::OpenMP_CXX)
endif()

# ── v1 Core library (original, still compiles) ─────────────────────────────────
# Includes energy_matrix + fast_optics so the pybind11 module links cleanly
# (bindings.cpp references SoftContactMatrix / ShannonEnergyMatrix / FastOPTICS).

add_library(shannon_core STATIC
    src/shannon.cpp
    src/energy_matrix.cpp
    src/fast_optics.cpp
)
target_include_directories(shannon_core PUBLIC src/)

if(SHANNON_USE_OPENMP)
    if(OpenMP_CXX_FOUND)
        target_link_libraries(shannon_core PUBLIC OpenMP::OpenMP_CXX)
    endif()
endif()

# ── pybind11 Python module ──────────────────────────────────────────────────────

if(SHANNON_BUILD_PYTHON)
    find_package(pybind11 CONFIG QUIET)
    if(NOT pybind11_FOUND)
        include(FetchContent)
        FetchContent_Declare(
            pybind11
            GIT_REPOSITORY https://github.com/pybind/pybind11.git
            GIT_TAG        v2.13.6
        )
        FetchContent_MakeAvailable(pybind11)
    endif()

    # Module name must match PYBIND11_MODULE(_core, ...) in bindings.cpp and
    # the Python import path shannon._core.
    pybind11_add_module(_core src/bindings.cpp)
    # shannon_v2 provides CollapseDetector + UnifiedDispatch (v2 bindings);
    # shannon_core provides the v1 surface + energy matrix + FastOPTICS.
    target_link_libraries(_core PRIVATE shannon_core shannon_v2)
    set_target_properties(_core PROPERTIES
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/python/shannon"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/python/shannon"
        ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/python/shannon"
    )
    # Multi-config generators (Xcode/MSVC) need per-config output dirs.
    foreach(cfg Debug Release RelWithDebInfo MinSizeRel)
        string(TOUPPER "${cfg}" cfg_u)
        set_target_properties(_core PROPERTIES
            LIBRARY_OUTPUT_DIRECTORY_${cfg_u} "${CMAKE_BINARY_DIR}/python/shannon"
            RUNTIME_OUTPUT_DIRECTORY_${cfg_u} "${CMAKE_BINARY_DIR}/python/shannon"
        )
    endforeach()
    install(TARGETS _core DESTINATION shannon)
endif()

# ── shannon-agent CLI ───────────────────────────────────────────────────────────

if(SHANNON_BUILD_AGENT)
    add_executable(shannon-agent apps/shannon-agent/main.cpp)
    target_link_libraries(shannon-agent PRIVATE shannon_v2)
    target_compile_definitions(shannon-agent PRIVATE ${SHANNON_DEFS})
    target_include_directories(shannon-agent PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated/)
    install(TARGETS shannon-agent DESTINATION bin)
endif()

# ── GoogleTest ──────────────────────────────────────────────────────────────────

if(SHANNON_BUILD_TESTS)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.15.2
    )
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)

    enable_testing()

    add_executable(shannon_tests tests/cpp/test_shannon.cpp)
    target_link_libraries(shannon_tests PRIVATE shannon_core GTest::gtest_main)

    add_executable(shannon_v2_tests
        tests/cpp/test_shannon_v2.cpp
    )
    target_link_libraries(shannon_v2_tests PRIVATE shannon_v2 GTest::gtest_main)
    target_compile_definitions(shannon_v2_tests PRIVATE ${SHANNON_DEFS})
    target_include_directories(shannon_v2_tests PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated/)

    # NEON kernel tests — standalone (no gtest) so the same file cross-compiles
    # for qemu-aarch64 via scripts/test_neon_qemu.sh on x86 CI hosts. On a
    # native aarch64 build (Apple Silicon, Graviton) it registers with ctest.
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64|armv8")
        add_executable(shannon_neon_kernel_tests tests/cpp/test_neon_kernels.cpp)
        target_link_libraries(shannon_neon_kernel_tests PRIVATE shannon_v2)
        target_compile_definitions(shannon_neon_kernel_tests PRIVATE ${SHANNON_DEFS})
        target_include_directories(shannon_neon_kernel_tests PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated/)
        add_test(NAME NeonKernels COMMAND shannon_neon_kernel_tests)
    endif()

    # SIMD exp accuracy tests — compiled with the widest available ISA flags so
    # the __AVX2__/__AVX512F__ code paths in simd_exp.hpp are actually exercised.
    add_executable(shannon_simd_exp_tests tests/cpp/test_simd_exp.cpp)
    target_link_libraries(shannon_simd_exp_tests PRIVATE shannon_v2 GTest::gtest_main)
    target_compile_definitions(shannon_simd_exp_tests PRIVATE ${SHANNON_DEFS})
    target_include_directories(shannon_simd_exp_tests PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated/)
    if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
        set(SHANNON_SIMD_EXP_FLAGS "")
        if(SHANNON_COMPILER_AVX2)
            set(SHANNON_SIMD_EXP_FLAGS "${SHANNON_SIMD_EXP_FLAGS} -mavx2 -mfma")
        endif()
        if(SHANNON_COMPILER_AVX512)
            set(SHANNON_SIMD_EXP_FLAGS "${SHANNON_SIMD_EXP_FLAGS} -mavx512f -mavx512dq -mavx512bw")
        endif()
        set_source_files_properties(tests/cpp/test_simd_exp.cpp
            PROPERTIES COMPILE_FLAGS "${SHANNON_SIMD_EXP_FLAGS}")
    endif()

    include(GoogleTest)
    gtest_discover_tests(shannon_tests)
    gtest_discover_tests(shannon_v2_tests)
    gtest_discover_tests(shannon_simd_exp_tests)
endif()
