cmake_minimum_required(VERSION 3.16)
project(shannon VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ── Options ──────────────────────────────────────────────────────────────────
option(SHANNON_BUILD_TESTS   "Build GoogleTest unit tests"    ON)
option(SHANNON_BUILD_PYTHON  "Build pybind11 Python module"   ON)
option(SHANNON_BUILD_CONTACT "Build soft contact matrix module" ON)
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

# ── Soft contact matrix library ──────────────────────────────────────────────
if(SHANNON_BUILD_CONTACT)
    add_library(shannon_contact STATIC src/contact/soft_contact_matrix.cpp)
    target_include_directories(shannon_contact PUBLIC src/)
    if(SHANNON_USE_OPENMP AND OpenMP_CXX_FOUND)
        target_link_libraries(shannon_contact PUBLIC OpenMP::OpenMP_CXX)
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

    if(SHANNON_BUILD_CONTACT)
        pybind11_add_module(_shannon_contact_cpp src/contact/bindings_contact.cpp)
        target_link_libraries(_shannon_contact_cpp PRIVATE shannon_contact)
        install(TARGETS _shannon_contact_cpp DESTINATION .)
    endif()
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

    if(SHANNON_BUILD_CONTACT)
        add_executable(contact_tests tests/cpp/test_soft_contact_matrix.cpp)
        target_link_libraries(contact_tests PRIVATE shannon_contact GTest::gtest_main)
        gtest_discover_tests(contact_tests)
    endif()
endif()
