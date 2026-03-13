cmake_minimum_required(VERSION 3.16)
project(shannon VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ── Options ──────────────────────────────────────────────────────────────────
option(SHANNON_BUILD_TESTS   "Build GoogleTest unit tests"    ON)
option(SHANNON_BUILD_PYTHON  "Build pybind11 Python module"   ON)
option(SHANNON_USE_OPENMP    "Enable OpenMP acceleration"     ON)

# ── Core library ─────────────────────────────────────────────────────────────
add_library(shannon_core STATIC src/shannon.cpp)
target_include_directories(shannon_core PUBLIC src/)

if(SHANNON_USE_OPENMP)
    find_package(OpenMP)
    if(OpenMP_CXX_FOUND)
        target_link_libraries(shannon_core PUBLIC OpenMP::OpenMP_CXX)
    endif()
endif()

# ── pybind11 Python module ───────────────────────────────────────────────────
if(SHANNON_BUILD_PYTHON)
    find_package(pybind11 CONFIG QUIET)
    if(NOT pybind11_FOUND)
        # Fallback: fetch pybind11
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

# ── GoogleTest ───────────────────────────────────────────────────────────────
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

    include(GoogleTest)
    gtest_discover_tests(shannon_tests)
endif()
