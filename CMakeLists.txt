cmake_minimum_required(VERSION 3.20)
project(shannon VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# =============================================================================
# Options
# =============================================================================
option(SHANNON_CUDA       "Build CUDA GPU kernels"          OFF)
option(SHANNON_METAL      "Build Metal GPU kernels (macOS)" OFF)
option(SHANNON_BUILD_TESTS "Build unit tests"               ON)
option(SHANNON_BUILD_PYTHON "Build Python bindings"         ON)

# =============================================================================
# SIMD detection  (compile-time; runtime dispatch via CPUID)
# =============================================================================
include(CheckCXXCompilerFlag)

check_cxx_compiler_flag("-mavx512f" SHANNON_COMPILER_HAS_AVX512)
check_cxx_compiler_flag("-mavx2"    SHANNON_COMPILER_HAS_AVX2)

# =============================================================================
# Compiler flags
# =============================================================================
if(MSVC)
    add_compile_options(/W4 /O2 /fp:fast)
    if(SHANNON_COMPILER_HAS_AVX512)
        add_compile_options(/arch:AVX512)
    elseif(SHANNON_COMPILER_HAS_AVX2)
        add_compile_options(/arch:AVX2)
    endif()
else()
    add_compile_options(-Wall -Wextra -O3 -ffast-math)
    if(SHANNON_COMPILER_HAS_AVX512)
        add_compile_options(-mavx512f -mavx512dq -mavx512bw -mfma)
    elseif(SHANNON_COMPILER_HAS_AVX2)
        add_compile_options(-mavx2 -mfma)
    endif()
endif()

# =============================================================================
# OpenMP (optional)
# =============================================================================
find_package(OpenMP QUIET)

# =============================================================================
# CUDA (optional)
# =============================================================================
if(SHANNON_CUDA)
    enable_language(CUDA)
    find_package(CUDAToolkit REQUIRED)
endif()

# =============================================================================
# Core static library
# =============================================================================
set(SHANNON_CORE_SOURCES
    src/shannon.cpp
    src/energy_matrix.cpp
    src/fast_optics.cpp
    src/contact/soft_contact_matrix.cpp
)

if(SHANNON_CUDA)
    list(APPEND SHANNON_CORE_SOURCES src/shannon_cuda.cu)
endif()

add_library(shannon_static STATIC ${SHANNON_CORE_SOURCES})
target_include_directories(shannon_static PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/src)

if(SHANNON_COMPILER_HAS_AVX512)
    target_compile_definitions(shannon_static PUBLIC SHANNON_HAS_AVX512)
endif()
if(SHANNON_COMPILER_HAS_AVX2)
    target_compile_definitions(shannon_static PUBLIC SHANNON_HAS_AVX2)
endif()

if(OpenMP_CXX_FOUND)
    target_link_libraries(shannon_static PUBLIC OpenMP::OpenMP_CXX)
    target_compile_definitions(shannon_static PUBLIC SHANNON_HAS_OPENMP)
endif()

if(SHANNON_CUDA)
    target_link_libraries(shannon_static PUBLIC CUDA::cudart)
    target_compile_definitions(shannon_static PUBLIC SHANNON_HAS_CUDA)
    set_target_properties(shannon_static PROPERTIES CUDA_SEPARABLE_COMPILATION ON)
endif()

# Metal (macOS only)
if(SHANNON_METAL AND APPLE)
    enable_language(OBJCXX)
    target_sources(shannon_static PRIVATE src/shannon_metal.mm)
    target_compile_definitions(shannon_static PUBLIC SHANNON_HAS_METAL)
    target_link_libraries(shannon_static PUBLIC "-framework Metal" "-framework Foundation" "-framework MetalPerformanceShaders")
    # Compile Metal shaders to metallib
    set(METAL_SHADER ${CMAKE_CURRENT_SOURCE_DIR}/src/shannon_metal.metal)
    set(METAL_AIR ${CMAKE_CURRENT_BINARY_DIR}/shannon_metal.air)
    set(METAL_LIB ${CMAKE_CURRENT_BINARY_DIR}/shannon_metal.metallib)
    add_custom_command(
        OUTPUT ${METAL_AIR}
        COMMAND xcrun -sdk macosx metal -c ${METAL_SHADER} -o ${METAL_AIR}
        DEPENDS ${METAL_SHADER}
        COMMENT "Compiling Metal shader"
    )
    add_custom_command(
        OUTPUT ${METAL_LIB}
        COMMAND xcrun -sdk macosx metallib ${METAL_AIR} -o ${METAL_LIB}
        DEPENDS ${METAL_AIR}
        COMMENT "Linking Metal shader library"
    )
    add_custom_target(metal_shaders ALL DEPENDS ${METAL_LIB})
    add_dependencies(shannon_static metal_shaders)
endif()

# =============================================================================
# Python bindings (pybind11)
# =============================================================================
if(SHANNON_BUILD_PYTHON)
    find_package(pybind11 CONFIG QUIET)
    if(NOT pybind11_FOUND)
        find_package(pybind11 QUIET)
    endif()
    if(pybind11_FOUND)
        pybind11_add_module(_core src/bindings.cpp)
        target_link_libraries(_core PRIVATE shannon_static)
        install(TARGETS _core DESTINATION shannon)

        pybind11_add_module(_shannon_contact_cpp src/contact/bindings_contact.cpp)
        target_link_libraries(_shannon_contact_cpp PRIVATE shannon_static)
        install(TARGETS _shannon_contact_cpp DESTINATION shannon_contact)
    else()
        message(STATUS "pybind11 not found — skipping Python bindings")
    endif()
endif()

# =============================================================================
# Tests (GoogleTest)
# =============================================================================
if(SHANNON_BUILD_TESTS)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.14.0
    )
    set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
    FetchContent_MakeAvailable(googletest)

    enable_testing()

    add_executable(test_shannon   tests/test_shannon.cpp)
    target_link_libraries(test_shannon PRIVATE shannon_static GTest::gtest_main)
    add_test(NAME ShannonTests COMMAND test_shannon)

    add_executable(test_energy_matrix tests/test_energy_matrix.cpp)
    target_link_libraries(test_energy_matrix PRIVATE shannon_static GTest::gtest_main)
    add_test(NAME EnergyMatrixTests COMMAND test_energy_matrix)

    add_executable(test_fast_optics tests/test_fast_optics.cpp)
    target_link_libraries(test_fast_optics PRIVATE shannon_static GTest::gtest_main)
    add_test(NAME FastOPTICSTests COMMAND test_fast_optics)

    add_executable(test_soft_contact tests/cpp/test_soft_contact_matrix.cpp)
    target_link_libraries(test_soft_contact PRIVATE shannon_static GTest::gtest_main)
    add_test(NAME SoftContactTests COMMAND test_soft_contact)
endif()
