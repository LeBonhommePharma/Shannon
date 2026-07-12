// hardware_detect.cpp — Runtime hardware capability detection for Shannon 2.0
//
// Ported from FlexAIDdS hardware_detect.cpp into shannon::hw namespace.
// Adds ARM NEON detection alongside existing x86 CPUID path.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/hardware_detect.hpp"

#include <sstream>
#include <cstring>

// ── x86 CPUID ────────────────────────────────────────────────────────────────
#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#  define SHANNON_X86 1
#  ifdef _MSC_VER
#    include <intrin.h>
     static void shannon_cpuid(int regs[4], int leaf) { __cpuid(regs, leaf); }
     static void shannon_cpuidex(int regs[4], int leaf, int sub) { __cpuidex(regs, leaf, sub); }
#  else
#    include <cpuid.h>
     static void shannon_cpuid(int regs[4], int leaf) {
         unsigned a, b, c, d;
         __cpuid_count(leaf, 0, a, b, c, d);
         std::memcpy(&regs[0], &a, sizeof(int));
         std::memcpy(&regs[1], &b, sizeof(int));
         std::memcpy(&regs[2], &c, sizeof(int));
         std::memcpy(&regs[3], &d, sizeof(int));
     }
     static void shannon_cpuidex(int regs[4], int leaf, int sub) {
         unsigned a, b, c, d;
         __cpuid_count(leaf, sub, a, b, c, d);
         std::memcpy(&regs[0], &a, sizeof(int));
         std::memcpy(&regs[1], &b, sizeof(int));
         std::memcpy(&regs[2], &c, sizeof(int));
         std::memcpy(&regs[3], &d, sizeof(int));
     }
#  endif
#else
#  define SHANNON_X86 0
#endif

// ── ARM NEON ─────────────────────────────────────────────────────────────────
#if defined(__ARM_NEON) || defined(__aarch64__)
#  define SHANNON_ARM 1
#else
#  define SHANNON_ARM 0
#endif

// ── OpenMP ───────────────────────────────────────────────────────────────────
#ifdef _OPENMP
#  include <omp.h>
#endif

// ── CUDA (compile-time gated) ────────────────────────────────────────────────
#ifdef SHANNON_USE_CUDA
#  include <cuda_runtime.h>
#endif

#ifdef SHANNON_USE_ROCM
#  include <hip/hip_runtime.h>
#endif

namespace shannon::hw {

static void detect_x86_simd(HardwareCapabilities& hw) {
#if SHANNON_X86
    int regs[4] = {};

    shannon_cpuid(regs, 1);
    hw.has_sse42 = (regs[2] & (1 << 20)) != 0;   // ECX bit 20
    hw.has_fma   = (regs[2] & (1 << 12)) != 0;   // ECX bit 12

    bool xsave_enabled = (regs[2] & (1 << 27)) != 0;   // ECX bit 27: OSXSAVE

    shannon_cpuidex(regs, 7, 0);
    bool avx2_cpuid    = (regs[1] & (1 <<  5)) != 0;   // EBX bit 5
    bool avx512f_cpuid = (regs[1] & (1 << 16)) != 0;   // EBX bit 16
    hw.has_avx512dq   = (regs[1] & (1 << 17)) != 0;    // EBX bit 17
    hw.has_avx512bw   = (regs[1] & (1 << 30)) != 0;    // EBX bit 30
    hw.has_avx512vnni = (regs[2] & (1 << 11)) != 0;    // ECX bit 11

    if (xsave_enabled) {
#  ifdef _MSC_VER
        unsigned long long xcr0 = _xgetbv(0);
#  else
        unsigned lo = 0, hi = 0;
        __asm__ __volatile__("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
        unsigned long long xcr0 = (static_cast<unsigned long long>(hi) << 32) | lo;
#  endif
        bool ymm_enabled = (xcr0 & 0x6) == 0x6;         // XMM + YMM state
        bool zmm_enabled = (xcr0 & 0xE6) == 0xE6;       // ZMM state (bits 1,2,5,6,7)

        hw.has_avx2 = avx2_cpuid && ymm_enabled;
        hw.has_avx512f = avx512f_cpuid && zmm_enabled;
    } else {
        hw.has_avx2 = false;
        hw.has_avx512f = false;
    }

    hw.has_avx512 = hw.has_avx512f && hw.has_avx512dq && hw.has_avx512bw;
#else
    (void)hw;
#endif
}

static void detect_arm_neon(HardwareCapabilities& hw) {
#if SHANNON_ARM
    // NEON/ASIMD is mandatory on AArch64. On 32-bit ARM, __ARM_NEON is set
    // when the compiler targets NEON (our build only enables this path then).
    hw.has_neon = true;
    // ARMv8 AArch64 always has FMA for floating-point NEON.
#  if defined(__aarch64__) || defined(__ARM_FEATURE_FMA)
    hw.has_neon_fma = true;
#  endif
    // SVE is optional; probe compile-time feature (runtime SVE length varies).
#  if defined(__ARM_FEATURE_SVE)
    hw.has_sve = true;
#  endif
#else
    (void)hw;
#endif
}

static void detect_openmp(HardwareCapabilities& hw) {
#ifdef _OPENMP
    hw.has_openmp = true;
    hw.openmp_max_threads = omp_get_max_threads();
#else
    hw.has_openmp = false;
    hw.openmp_max_threads = 1;
#endif
}

static void detect_eigen(HardwareCapabilities& hw) {
#ifdef SHANNON_USE_EIGEN
    hw.has_eigen = true;
#else
    hw.has_eigen = false;
#endif
}

static void detect_cuda(HardwareCapabilities& hw) {
#ifdef SHANNON_USE_CUDA
    int count = 0;
    cudaError_t err = cudaGetDeviceCount(&count);
    if (err != cudaSuccess || count <= 0) return;

    hw.has_cuda = true;
    hw.cuda_device_count = count;

    cudaDeviceProp prop{};
    if (cudaGetDeviceProperties(&prop, 0) == cudaSuccess) {
        hw.cuda_device_name = prop.name;
        hw.cuda_sm_major    = prop.major;
        hw.cuda_sm_minor    = prop.minor;
        hw.cuda_global_mem  = prop.totalGlobalMem;
        hw.cuda_arch        = "sm_" + std::to_string(prop.major * 10 + prop.minor);
    }
#else
    (void)hw;
#endif
}

static void detect_metal(HardwareCapabilities& hw) {
#ifdef SHANNON_USE_METAL
    // TODO: Runtime Metal probe via MTLCreateSystemDefaultDevice() requires
    // an Objective-C++ bridge (e.g. hardware_detect_metal.mm). Without it,
    // we cannot confirm GPU availability at runtime — only at compile time.
    // For now, claim Metal only if we're on Apple hardware with the build flag.
    // This may falsely report Metal on headless/CI macOS without a GPU.
#  if defined(__APPLE__) && defined(__aarch64__)
    hw.has_metal = true;
    hw.metal_gpu_name = "Apple GPU (Metal-capable)";
#  elif defined(__APPLE__)
    hw.has_metal = true;
    hw.metal_gpu_name = "macOS GPU (Metal build-enabled, unprobed)";
#  endif
#else
    (void)hw;
#endif
}

static void detect_rocm(HardwareCapabilities& hw) {
#ifdef SHANNON_USE_ROCM
    int count = 0;
    hipError_t err = hipGetDeviceCount(&count);
    if (err != hipSuccess || count <= 0) return;

    hw.has_rocm = true;
    hw.rocm_device_count = count;

    hipDeviceProp_t prop{};
    if (hipGetDeviceProperties(&prop, 0) == hipSuccess) {
        hw.rocm_device_name = prop.name;
        hw.rocm_global_mem  = prop.totalGlobalMem;
#if defined(__HIP_PLATFORM_AMD__) || defined(__HIP_PLATFORM_HCC__)
        if (prop.gcnArchName[0] != '\0') {
            hw.rocm_arch = prop.gcnArchName;
        } else if (prop.gcnArch > 0) {
            hw.rocm_arch = "gfx" + std::to_string(prop.gcnArch);
        } else {
            hw.rocm_arch = "gfx-unknown";
        }
#else
        hw.rocm_arch = "hip-generic";
#endif
    }
#else
    (void)hw;
#endif
}

std::string HardwareCapabilities::summary() const {
    std::ostringstream os;
    os << "[shannon::hw] Hardware Capabilities:\n";

    if (has_cuda)
        os << "[shannon::hw]   CUDA: " << cuda_device_name
           << " (" << cuda_arch << ", "
           << (cuda_global_mem >> 20) << " MB)\n";
    else
        os << "[shannon::hw]   CUDA: not available\n";

    if (has_metal)
        os << "[shannon::hw]   Metal: " << metal_gpu_name << "\n";
    else
        os << "[shannon::hw]   Metal: not available\n";

    if (has_rocm)
        os << "[shannon::hw]   ROCm: " << rocm_device_name
           << " (" << rocm_arch << ", "
           << (rocm_global_mem >> 20) << " MB)\n";
    else
        os << "[shannon::hw]   ROCm: not available\n";

    // Report all detected SIMD features (not else-if): multi-ISA builds matter.
    bool any_simd = false;
    if (has_avx512) {
        os << "[shannon::hw]   AVX-512: F+DQ+BW"
           << (has_avx512vnni ? "+VNNI" : "") << "\n";
        any_simd = true;
    }
    if (has_avx2) {
        os << "[shannon::hw]   AVX2+FMA: " << (has_fma ? "yes" : "avx2-only") << "\n";
        any_simd = true;
    }
    if (has_sse42) {
        os << "[shannon::hw]   SSE4.2: yes\n";
        any_simd = true;
    }
    if (has_neon) {
        os << "[shannon::hw]   NEON/ASIMD: yes"
           << (has_neon_fma ? " +FMA" : "")
           << (has_sve ? " +SVE" : "")
           << "\n";
        any_simd = true;
    }
    if (!any_simd)
        os << "[shannon::hw]   SIMD: baseline only\n";

    os << "[shannon::hw]   OpenMP: "
       << (has_openmp ? std::to_string(openmp_max_threads) + " threads" : "disabled")
       << "\n";

    os << "[shannon::hw]   Eigen: " << (has_eigen ? "yes" : "no") << "\n";

    return os.str();
}

const HardwareCapabilities& detect_hardware() {
    static HardwareCapabilities hw = [] {
        HardwareCapabilities caps;
        detect_x86_simd(caps);
        detect_arm_neon(caps);
        detect_openmp(caps);
        detect_eigen(caps);
        detect_cuda(caps);
        detect_rocm(caps);
        detect_metal(caps);
        return caps;
    }();
    return hw;
}

}  // namespace shannon::hw
