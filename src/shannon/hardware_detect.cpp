// hardware_detect.cpp — Runtime hardware capability detection for Shannon 2.0
//
// Ported from FlexAIDdS hardware_detect.cpp into shannon::hw namespace.
// Adds ARM NEON detection alongside existing x86 CPUID path.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/hardware_detect.hpp"

#include <sstream>

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
         __cpuid_count(leaf, 0,
                       reinterpret_cast<unsigned&>(regs[0]),
                       reinterpret_cast<unsigned&>(regs[1]),
                       reinterpret_cast<unsigned&>(regs[2]),
                       reinterpret_cast<unsigned&>(regs[3]));
     }
     static void shannon_cpuidex(int regs[4], int leaf, int sub) {
         __cpuid_count(leaf, sub,
                       reinterpret_cast<unsigned&>(regs[0]),
                       reinterpret_cast<unsigned&>(regs[1]),
                       reinterpret_cast<unsigned&>(regs[2]),
                       reinterpret_cast<unsigned&>(regs[3]));
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

    shannon_cpuidex(regs, 7, 0);
    hw.has_avx2       = (regs[1] & (1 <<  5)) != 0;  // EBX bit 5
    hw.has_avx512f    = (regs[1] & (1 << 16)) != 0;  // EBX bit 16
    hw.has_avx512dq   = (regs[1] & (1 << 17)) != 0;  // EBX bit 17
    hw.has_avx512bw   = (regs[1] & (1 << 30)) != 0;  // EBX bit 30
    hw.has_avx512vnni = (regs[2] & (1 << 11)) != 0;  // ECX bit 11

    hw.has_avx512 = hw.has_avx512f && hw.has_avx512dq && hw.has_avx512bw;
#else
    (void)hw;
#endif
}

static void detect_arm_neon(HardwareCapabilities& hw) {
#if SHANNON_ARM
    hw.has_neon = true;
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
    hw.has_metal = true;
    hw.metal_gpu_name = "Apple GPU (Metal-capable)";
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

    if (has_avx512)
        os << "[shannon::hw]   AVX-512: F+DQ+BW"
           << (has_avx512vnni ? "+VNNI" : "") << "\n";
    else if (has_avx2)
        os << "[shannon::hw]   AVX2+FMA: yes\n";
    else if (has_sse42)
        os << "[shannon::hw]   SSE4.2: yes\n";
    else if (has_neon)
        os << "[shannon::hw]   NEON: yes (ARM)\n";
    else
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
