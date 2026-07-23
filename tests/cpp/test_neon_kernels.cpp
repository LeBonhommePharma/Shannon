// test_neon_kernels.cpp — Standalone NEON kernel validation (no gtest)
//
// Validates the NEON vectorized transcendentals (shannon_exp_neon,
// shannon_log2_neon) against libm, and the three NEON entropy kernels against
// the scalar reference kernels, plus analytic ground truths.
//
// Standalone (assert-style, exit code 0/1) so it can be cross-compiled with
// aarch64-linux-gnu-g++ and run under qemu-aarch64 on an x86 CI host without
// cross-building GoogleTest — see scripts/test_neon_qemu.sh. On a native
// aarch64 host (Apple Silicon, Graviton) it builds and runs directly and is
// registered with ctest.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#if defined(__ARM_NEON) || defined(__aarch64__)

#include "shannon/entropy.hpp"
#include "shannon/simd_exp.hpp"
#include "shannon/simd_log2.hpp"

#include <arm_neon.h>

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

namespace sk = shannon::kernels;

static int failures = 0;

#define CHECK(cond, ...)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            std::printf("FAIL %s:%d: ", __FILE__, __LINE__);                 \
            std::printf(__VA_ARGS__);                                        \
            std::printf("\n");                                               \
            ++failures;                                                      \
        }                                                                    \
    } while (0)

static double exp_neon1(double x) {
    double out[2];
    vst1q_f64(out, sk::simd::shannon_exp_neon(vdupq_n_f64(x)));
    return out[0];
}

static double log2_neon1(double x) {
    double out[2];
    vst1q_f64(out, sk::simd::shannon_log2_neon(vdupq_n_f64(x)));
    return out[0];
}

int main() {
    std::mt19937_64 rng(42);

    // ── exp accuracy vs libm over the normal-result domain [-708, 0] ──
    // (below kExpFlush = -708 the kernel saturates to +0.0 by design; the
    //  true value there is subnormal/zero and contributes nothing to Z >= 1)
    {
        double max_rel = 0.0;
        std::uniform_real_distribution<double> ud(-708.0, 0.0);
        for (int i = 0; i < 2'000'000; ++i) {
            const double x = ud(rng);
            const double want = std::exp(x);
            const double got = exp_neon1(x);
            if (want > 0.0) {
                const double rel = std::fabs(got - want) / want;
                if (rel > max_rel) max_rel = rel;
            }
        }
        std::printf("exp  max rel err (2M samples, [-708,0]): %.3e\n", max_rel);
        CHECK(max_rel < 1e-13, "exp accuracy %.3e >= 1e-13", max_rel);
    }
    // exp edge cases + deep-negative saturation (regression: pre-saturation,
    // the 2^n exponent-bit trick wrapped for x < ~-1418 and returned Inf/garbage)
    CHECK(exp_neon1(0.0) == 1.0, "exp(0) != 1 exactly: %.17g", exp_neon1(0.0));
    CHECK(exp_neon1(-0.0) == 1.0, "exp(-0) != 1");
    for (double x : {-709.0, -745.0, -800.0, -1418.0, -1420.0, -2000.0, -1e6, -1e300}) {
        const double v = exp_neon1(x);
        CHECK(v == 0.0, "exp(%g) must saturate to +0, got %g", x, v);
        CHECK(!std::signbit(v), "exp(%g) must be +0, not -0", x);
    }

    // ── log2 accuracy vs libm over p ∈ (1e-300, 1] ──
    {
        double max_rel = 0.0;
        std::uniform_real_distribution<double> le(-300.0, 0.0);
        for (int i = 0; i < 2'000'000; ++i) {
            const double p = std::pow(10.0, le(rng));
            const double want = std::log2(p);
            const double got = log2_neon1(p);
            if (want != 0.0) {
                const double rel = std::fabs(got - want) / std::fabs(want);
                if (rel > max_rel) max_rel = rel;
            }
        }
        std::printf("log2 max rel err (2M samples, (1e-300,1]): %.3e\n", max_rel);
        CHECK(max_rel < 1e-12, "log2 accuracy %.3e >= 1e-12", max_rel);
    }
    CHECK(log2_neon1(1.0) == 0.0, "log2(1) != 0 exactly: %.17g", log2_neon1(1.0));
    CHECK(std::fabs(log2_neon1(2.0) - 1.0) < 1e-15, "log2(2) != 1");
    CHECK(std::fabs(log2_neon1(0.5) + 1.0) < 1e-15, "log2(0.5) != -1");

    // ── entropy kernels: NEON vs scalar reference, random distributions ──
    {
        double worst_cfg = 0.0, worst_probs = 0.0, worst_lp = 0.0;
        std::uniform_real_distribution<double> scale_d(0.05, 30.0);
        std::uniform_int_distribution<std::size_t> n_d(2, 5000);
        std::normal_distribution<double> nd(0.0, 1.0);

        for (int t = 0; t < 400; ++t) {
            const std::size_t n = n_d(rng);
            const double sc = scale_d(rng);
            std::vector<double> w(n), p(n), lp(n);
            double mx = -1e300;
            for (auto& v : w) { v = nd(rng) * sc; if (v > mx) mx = v; }
            double Z = 0.0;
            for (std::size_t i = 0; i < n; ++i) { p[i] = std::exp(w[i] - mx); Z += p[i]; }
            for (std::size_t i = 0; i < n; ++i) {
                p[i] /= Z;
                lp[i] = std::log(p[i] > 1e-300 ? p[i] : 1e-300);
            }

            worst_cfg = std::fmax(worst_cfg,
                std::fabs(sk::configurational_entropy_neon(w.data(), n) -
                          sk::configurational_entropy_scalar(w.data(), n)));
            worst_probs = std::fmax(worst_probs,
                std::fabs(sk::entropy_from_probs_neon(p.data(), n) -
                          sk::entropy_from_probs_scalar(p.data(), n)));
            worst_lp = std::fmax(worst_lp,
                std::fabs(sk::entropy_from_logprobs_neon(lp.data(), n) -
                          sk::entropy_from_logprobs_scalar(lp.data(), n)));
        }
        std::printf("kernel |dH| vs scalar over 400 trials: cfg=%.3e probs=%.3e logprobs=%.3e\n",
                    worst_cfg, worst_probs, worst_lp);
        CHECK(worst_cfg   < 1e-11, "configurational NEON vs scalar drift %.3e", worst_cfg);
        CHECK(worst_probs < 1e-11, "probs NEON vs scalar drift %.3e", worst_probs);
        CHECK(worst_lp    < 1e-11, "logprobs NEON vs scalar drift %.3e", worst_lp);
    }

    // ── analytic ground truths ──
    for (std::size_t n : {2ul, 16ul, 1024ul, 131072ul}) {
        std::vector<double> z(n, 0.0);
        const double h = sk::configurational_entropy_neon(z.data(), n);
        CHECK(std::fabs(h - std::log2(double(n))) < 1e-9,
              "uniform n=%zu: H=%.12f want %.12f", n, h, std::log2(double(n)));
    }
    {
        std::vector<double> onehot(1000, -50.0);
        onehot[0] = 50.0;
        CHECK(std::fabs(sk::configurational_entropy_neon(onehot.data(), 1000)) < 1e-6,
              "one-hot H != 0");
        // shift invariance
        std::vector<double> w(5000);
        std::normal_distribution<double> nd(0.0, 3.0);
        for (auto& v : w) v = nd(rng);
        std::vector<double> ws(w);
        for (auto& v : ws) v += 1e4;
        CHECK(std::fabs(sk::configurational_entropy_neon(w.data(), w.size()) -
                        sk::configurational_entropy_neon(ws.data(), ws.size())) < 1e-8,
              "shift invariance violated");
        // masked-zero probs lane: p=0 must contribute exactly 0, not NaN
        std::vector<double> pz = {0.5, 0.0, 0.25, 0.25, 0.0, 0.0};
        const double h = sk::entropy_from_probs_neon(pz.data(), pz.size());
        CHECK(!std::isnan(h), "zero-prob lane produced NaN");
        CHECK(std::fabs(h - 1.5) < 1e-12, "H({.5,.25,.25}) != 1.5, got %.15f", h);
    }

    if (failures == 0) {
        std::printf("ALL NEON KERNEL CHECKS PASS\n");
        return 0;
    }
    std::printf("%d FAILURES\n", failures);
    return 1;
}

#else
#include <cstdio>
int main() {
    std::printf("SKIP: not an ARM/NEON build\n");
    return 0;
}
#endif
