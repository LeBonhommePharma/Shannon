// entropy_std_simd.cpp — portable SIMD entropy kernels (P1928 / experimental)
//
// Instantiates entropy_algorithm.hpp over abi::native<double>:
//   P1928 `std::simd::vec<double>` when `__cpp_lib_simd`, else Parallelism TS
//   `native_simd<double>`. Compiled with the same -mavx2 -mfma flags as
//   entropy_avx2.cpp on x86 so native width is 4. Not selected by
//   UnifiedDispatch::best_backend (AVX2/AVX-512 stay preferred); override
//   Backend::STD_SIMD to run these kernels. Horner exp/log2 — never scalar
//   std::exp per lane.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/entropy.hpp"

#if !defined(SHANNON_NO_STD_SIMD)
#include "shannon/entropy_algorithm.hpp"
#include "shannon/simd_generic.hpp"
#endif

#include <cstddef>
#include <span>

namespace shannon::kernels {

#if !defined(SHANNON_NO_STD_SIMD) && defined(SHANNON_SIMD_GENERIC)

namespace {

struct StdSimdTraits {
    using vec = simd::abi::native<double>;
    static constexpr std::size_t width = simd::abi::lane_count<vec>();

    [[nodiscard]] static vec set1(double x) noexcept { return vec(x); }
    [[nodiscard]] static vec zero() noexcept { return vec(0.0); }
    [[nodiscard]] static vec load(const double* p) noexcept {
        return simd::abi::load<vec>(p);
    }
    [[nodiscard]] static vec sub(vec a, vec b) noexcept { return a - b; }
    [[nodiscard]] static vec add(vec a, vec b) noexcept { return a + b; }
    [[nodiscard]] static vec mul(vec a, vec b) noexcept { return a * b; }
    [[nodiscard]] static vec fmadd(vec a, vec b, vec c) noexcept {
        return simd::abi::fma(a, b, c);
    }
    [[nodiscard]] static vec exp(vec x) noexcept { return simd::shannon_exp_generic(x); }
    [[nodiscard]] static vec log2(vec x) noexcept { return simd::shannon_log2_generic(x); }
    [[nodiscard]] static vec select_gt(vec values, double threshold, vec if_true) noexcept {
        vec out = zero();
        simd::abi::where(values > vec(threshold), out) = if_true;
        return out;
    }
    [[nodiscard]] static vec select_finite(vec x, vec v) noexcept {
        vec out = zero();
        simd::abi::where(simd::abi::isfinite(x), out) = v;
        return out;
    }
    [[nodiscard]] static double hsum(vec v) noexcept { return simd::abi::reduce(v); }
};

}  // namespace

bool std_simd_kernels_built() noexcept { return true; }

StdSimdFlavor std_simd_flavor() noexcept {
#if defined(SHANNON_SIMD_GENERIC_P1928)
    return StdSimdFlavor::P1928;
#else
    return StdSimdFlavor::ExperimentalTs;
#endif
}

double configurational_entropy_std_simd(std::span<const double> weights) noexcept {
    return configurational_entropy<StdSimdTraits>(weights);
}

double entropy_from_probs_std_simd(std::span<const double> probs) noexcept {
    return entropy_from_probs<StdSimdTraits>(probs);
}

double entropy_from_logprobs_std_simd(std::span<const double> logprobs) noexcept {
    return entropy_from_logprobs<StdSimdTraits>(logprobs);
}

#else

bool std_simd_kernels_built() noexcept { return false; }

StdSimdFlavor std_simd_flavor() noexcept { return StdSimdFlavor::Stub; }

double configurational_entropy_std_simd(std::span<const double> weights) noexcept {
    return configurational_entropy_scalar(weights);
}

double entropy_from_probs_std_simd(std::span<const double> probs) noexcept {
    return entropy_from_probs_scalar(probs);
}

double entropy_from_logprobs_std_simd(std::span<const double> logprobs) noexcept {
    return entropy_from_logprobs_scalar(logprobs);
}

#endif

}  // namespace shannon::kernels
