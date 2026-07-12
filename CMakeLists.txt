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
option(SHANNON_USE_CUDA       "Enable CUDA GPU kernels"         OFF)
option(SHANNON_USE_ROCM       "Enable ROCm/HIP GPU kernels"     OFF)
option(SHANNON_USE_METAL      "Enable Metal GPU kernels"        OFF)
option(SHANNON_USE_EIGEN      "Enable Eigen vectorization"      OFF)

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
if(SHANNON_USE_CUDA)
    list(APPEND SHANNON_DEFS SHANNON_USE_CUDA)
    enable_language(CUDA)
endif()
if(SHANNON_USE_ROCM)
    list(APPEND SHANNON_DEFS SHANNON_USE_ROCM)
endif()
if(SHANNON_USE_METAL)
    list(APPEND SHANNON_DEFS SHANNON_USE_METAL)
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

add_library(shannon_core STATIC src/shannon.cpp)
target_include_directories(shannon_core PUBLIC src/)

if(SHANNON_USE_OPENMP)
    if(OpenMP_CXX_FOUND)
        target_link_libraries(shannon_core PUBLIC OpenMP::OpenMP_CXX)
    endif()
endif()

# ── CUDA GPU kernels ────────────────────────────────────────────────────────────

if(SHANNON_USE_CUDA)
    add_library(shannon_cuda STATIC src/shannon/entropy_gpu.cu)
    target_include_directories(shannon_cuda PUBLIC src/)
    target_compile_definitions(shannon_cuda PUBLIC SHANNON_USE_CUDA)
    target_link_libraries(shannon_v2 PUBLIC shannon_cuda)
endif()

# ── Metal GPU kernels ───────────────────────────────────────────────────────────

if(SHANNON_USE_METAL AND APPLE)
    add_custom_command(
        OUTPUT ${CMAKE_CURRENT_BINARY_DIR}/entropy_metal.metallib
        COMMAND xcrun -sdk macosx metal -c ${CMAKE_CURRENT_SOURCE_DIR}/src/shannon/entropy_metal.metal
                -o ${CMAKE_CURRENT_BINARY_DIR}/entropy_metal.air
        COMMAND xcrun -sdk macosx metallib ${CMAKE_CURRENT_BINARY_DIR}/entropy_metal.air
                -o ${CMAKE_CURRENT_BINARY_DIR}/entropy_metal.metallib
        DEPENDS src/shannon/entropy_metal.metal
        COMMENT "Compiling Metal shader"
    )
    add_custom_target(shannon_metal ALL DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/entropy_metal.metallib)
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

    pybind11_add_module(_shannon_cpp src/bindings.cpp)
    target_link_libraries(_shannon_cpp PRIVATE shannon_core)
    install(TARGETS _shannon_cpp DESTINATION .)
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

    include(GoogleTest)
    gtest_discover_tests(shannon_tests)
    gtest_discover_tests(shannon_v2_tests)
endif()
