// test_shannon_v2.cpp — GoogleTest suite for Shannon 2.0
//
// Tests: scalar kernels, unified dispatch, collapse detector, handrail,
// TurboQuant, and stream ingestion.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include <gtest/gtest.h>

#include "shannon/config.hpp"
#include "shannon/entropy.hpp"
#include "shannon/unified_dispatch.hpp"
#include "shannon/collapse_detector.hpp"
#include "shannon/handrail.hpp"
#include "shannon/turbo_quant.hpp"
#include "shannon/types.hpp"
#include "shannon/terminal_agent.hpp"
#include "shannon/stream_ingest.hpp"

#include <cmath>
#include <limits>
#include <string>
#include <vector>
#include <unistd.h>

using namespace shannon;

// ─── Scalar entropy kernel tests ────────────────────────────────────────────

TEST(ScalarEntropy, UniformDistribution) {
    std::vector<double> logits(16, 0.0);
    double h = kernels::configurational_entropy_scalar(logits.data(), 16);
    EXPECT_NEAR(h, std::log2(16.0), 1e-10);
}

TEST(ScalarEntropy, SingleElement) {
    double val = 1.0;
    double h = kernels::configurational_entropy_scalar(&val, 1);
    EXPECT_DOUBLE_EQ(h, 0.0);
}

TEST(ScalarEntropy, EmptyInput) {
    double h = kernels::configurational_entropy_scalar(nullptr, 0);
    EXPECT_DOUBLE_EQ(h, 0.0);
}

TEST(ScalarEntropy, TwoElements) {
    double logits[] = {0.0, 0.0};
    double h = kernels::configurational_entropy_scalar(logits, 2);
    EXPECT_NEAR(h, 1.0, 1e-10);
}

TEST(ScalarEntropy, DeterministicPeak) {
    std::vector<double> logits(100, -100.0);
    logits[0] = 0.0;
    double h = kernels::configurational_entropy_scalar(logits.data(), 100);
    EXPECT_LT(h, 0.1);
}

TEST(ScalarEntropyFromProbs, UniformProbs) {
    std::vector<double> probs(8, 1.0 / 8.0);
    double h = kernels::entropy_from_probs_scalar(probs.data(), 8);
    EXPECT_NEAR(h, 3.0, 1e-10);
}

TEST(ScalarEntropyFromLogprobs, UniformLogprobs) {
    double lp = std::log(1.0 / 4.0);
    std::vector<double> logprobs(4, lp);
    double h = kernels::entropy_from_logprobs_scalar(logprobs.data(), 4);
    EXPECT_NEAR(h, 2.0, 1e-10);
}

// ─── Entropy cross-check tests ──────────────────────────────────────────────

TEST(EntropyCrossCheck, ProbsMatchLogprobs) {
    double probs[] = {0.1, 0.2, 0.3, 0.4};
    double logprobs[] = {std::log(0.1), std::log(0.2), std::log(0.3), std::log(0.4)};

    double h_probs = kernels::entropy_from_probs_scalar(probs, 4);
    double h_logprobs = kernels::entropy_from_logprobs_scalar(logprobs, 4);

    EXPECT_NEAR(h_probs, h_logprobs, 1e-12);
}

TEST(EntropyCrossCheck, ConfigurationalMatchesProbs) {
    double probs[] = {0.1, 0.2, 0.3, 0.4};
    double logits[] = {std::log(0.1), std::log(0.2), std::log(0.3), std::log(0.4)};

    double h_config = kernels::configurational_entropy_scalar(logits, 4);
    double h_probs = kernels::entropy_from_probs_scalar(probs, 4);

    EXPECT_NEAR(h_config, h_probs, 1e-10);
}

TEST(EntropyCrossCheck, BinaryEntropy) {
    double probs[] = {0.5, 0.5};
    double h = kernels::entropy_from_probs_scalar(probs, 2);
    EXPECT_NEAR(h, 1.0, 1e-14);
}

TEST(EntropyCrossCheck, DeterministicPeak) {
    double probs[] = {1.0, 0.0, 0.0, 0.0};
    double h = kernels::entropy_from_probs_scalar(probs, 4);
    EXPECT_NEAR(h, 0.0, 1e-14);
}

// ─── Expansion detection tests ─────────────────────────────────────────────

TEST(ExpansionDetection, DetectsSuddenExpansion) {
    CollapseDetector det(8, -3.2, +3.2);

    std::vector<double> low_entropy(1024, -1000.0);
    low_entropy[0] = 0.0;

    for (int i = 0; i < 8; ++i) {
        det.add_logits(low_entropy);
    }

    std::vector<double> high_entropy(1024);
    for (std::size_t i = 0; i < 1024; ++i) {
        high_entropy[i] = static_cast<double>(i) * 0.01;
    }

    auto r = det.add_logits(high_entropy);
    EXPECT_TRUE(r.expanded);
    EXPECT_GT(r.entropy, 1.0);
    EXPECT_EQ(r.event, EntropyEvent::EXPANSION);
}

TEST(ExpansionDetection, ExpansionCallbackFires) {
    bool expansion_fired = false;
    CollapseDetector det(4, -2.0, +2.0);
    det.set_callback([&](const CollapseResult& r) {
        if (r.expanded) expansion_fired = true;
    });

    std::vector<double> peak(16, -100.0);
    peak[0] = 0.0;
    for (int i = 0; i < 4; ++i) det.add_logits(peak);

    std::vector<double> broad(16, 0.0);
    det.add_logits(broad);

    EXPECT_TRUE(expansion_fired);
}

TEST(ExpansionDetection, NoExpansionOnStableInput) {
    CollapseDetector det(8, -3.2, +3.2);

    std::vector<double> logits(16, 0.0);
    for (int i = 0; i < 20; ++i) {
        auto r = det.add_logits(logits);
        if (i >= 8) {
            EXPECT_FALSE(r.expanded);
        }
    }
}

TEST(ExpansionDetection, SymmetricThresholds) {
    CollapseDetector det(4, -2.0, +2.0);

    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);

    auto r_collapse = det.push_entropy(2.0);
    EXPECT_TRUE(r_collapse.collapsed);
    EXPECT_FALSE(r_collapse.expanded);

    det.reset();
    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);

    auto r_expand = det.push_entropy(18.0);
    EXPECT_TRUE(r_expand.expanded);
    EXPECT_FALSE(r_expand.collapsed);
}

// ─── Oscillation detection tests ────────────────────────────────────────────

TEST(OscillationDetection, DetectsRapidAlternation) {
    CollapseDetector det(4, -2.0, +2.0, 6);

    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);

    det.push_entropy(2.0);
    det.push_entropy(18.0);
    det.push_entropy(2.0);
    det.push_entropy(18.0);

    auto r = det.push_entropy(2.0);
    EXPECT_TRUE(r.oscillating);
    EXPECT_EQ(r.event, EntropyEvent::OSCILLATION);
}

TEST(OscillationDetection, NoOscillationOnStableInput) {
    CollapseDetector det(8, -3.2, +3.2, 5);

    for (int i = 0; i < 20; ++i) {
        auto r = det.push_entropy(10.0);
        EXPECT_FALSE(r.oscillating);
    }
}

TEST(OscillationDetection, NoOscillationOnSingleCollapse) {
    CollapseDetector det(4, -2.0, +2.0, 5);

    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);
    auto r = det.push_entropy(2.0);

    EXPECT_TRUE(r.collapsed);
    EXPECT_FALSE(r.oscillating);
}

// ─── EntropyEvent enum tests ────────────────────────────────────────────────

TEST(EntropyEvent, EnumValues) {
    EXPECT_EQ(static_cast<int>(EntropyEvent::NONE), 0);
    EXPECT_EQ(static_cast<int>(EntropyEvent::COLLAPSE), 1);
    EXPECT_EQ(static_cast<int>(EntropyEvent::EXPANSION), 2);
    EXPECT_EQ(static_cast<int>(EntropyEvent::OSCILLATION), 3);
}

TEST(EntropyEvent, ClassifyCorrectly) {
    CollapseDetector det(4, -2.0, +2.0);

    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);

    auto r_normal = det.push_entropy(10.5);
    EXPECT_EQ(r_normal.event, EntropyEvent::NONE);

    auto r_collapse = det.push_entropy(2.0);
    EXPECT_EQ(r_collapse.event, EntropyEvent::COLLAPSE);
}

// ─── Handrail expansion/oscillation tests ────────────────────────────────────

TEST(Handrail, CountsExpansions) {
    HandrailConfig cfg;
    cfg.on_expansion = HandrailAction::LOG_ONLY;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.log_path = "/dev/null";

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 15.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = 7.0, .z_score = 7.0, .collapsed = false,
        .expanded = true, .oscillating = false,
        .event = EntropyEvent::EXPANSION,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_expansions(), 1);
    EXPECT_EQ(engine.total_collapses(), 0);
}

TEST(Handrail, CountsOscillations) {
    HandrailConfig cfg;
    cfg.on_oscillation = HandrailAction::LOG_ONLY;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.log_path = "/dev/null";

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 5.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -3.0, .z_score = -3.0, .collapsed = false,
        .expanded = false, .oscillating = true,
        .event = EntropyEvent::OSCILLATION,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_oscillations(), 1);
    EXPECT_EQ(engine.total_collapses(), 0);
}

TEST(Handrail, ExpansionActionFires) {
    HandrailConfig cfg;
    cfg.on_expansion = HandrailAction::KILL;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.log_path = "/dev/null";
    cfg.monitored_pid = static_cast<pid_t>(999999999);
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 15.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = 7.0, .z_score = 7.0, .collapsed = false,
        .expanded = true, .oscillating = false,
        .event = EntropyEvent::EXPANSION,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_expansions(), 1);
    EXPECT_EQ(engine.escalated_actions(), 1);
}

TEST(Handrail, ExpansionResetsConsecutiveCollapses) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::KILL;
    cfg.on_expansion = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 2;
    cfg.log_path = "/dev/null";
    cfg.monitored_pid = static_cast<pid_t>(999999999);
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult collapsed{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .expanded = false, .oscillating = false,
        .event = EntropyEvent::COLLAPSE,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };
    CollapseResult expanded{
        .entropy = 15.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = 7.0, .z_score = 7.0, .collapsed = false,
        .expanded = true, .oscillating = false,
        .event = EntropyEvent::EXPANSION,
        .token_index = 1, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(collapsed);
    engine.evaluate(expanded);
    engine.evaluate(collapsed);

    EXPECT_EQ(engine.total_collapses(), 2);
    EXPECT_EQ(engine.escalated_actions(), 0);
}

// ─── Config expansion tests ─────────────────────────────────────────────────

TEST(Config, ExpansionConstants) {
    EXPECT_DOUBLE_EQ(kDefaultExpansionThreshold, +3.2);
    EXPECT_EQ(kDefaultOscillationWindow, 5u);
}

TEST(EntropyCrossCheck, LargeVocabulary) {
    std::vector<double> logits(1000, 0.0);
    double h = kernels::configurational_entropy_scalar(logits.data(), 1000);
    EXPECT_NEAR(h, std::log2(1000.0), 1e-8);
}

// ─── Entropy edge case tests ────────────────────────────────────────────────

TEST(Entropy, NaNInfInput) {
    std::vector<double> with_nan = {1.0, std::numeric_limits<double>::quiet_NaN(), 2.0};
    double h = kernels::configurational_entropy_scalar(with_nan.data(), 3);
    EXPECT_FALSE(std::isnan(h));

    std::vector<double> with_inf = {1.0, std::numeric_limits<double>::infinity(), 2.0};
    h = kernels::configurational_entropy_scalar(with_inf.data(), 3);
    EXPECT_FALSE(std::isnan(h));
    EXPECT_GE(h, 0.0);

    std::vector<double> all_neg_inf(4, -std::numeric_limits<double>::infinity());
    h = kernels::configurational_entropy_scalar(all_neg_inf.data(), 4);
    EXPECT_FALSE(std::isnan(h));
    EXPECT_GE(h, 0.0);
}

// ─── Config tests ───────────────────────────────────────────────────────────

TEST(Config, Constants) {
    EXPECT_NEAR(kLn2, 0.693147180559945, 1e-10);
    EXPECT_NEAR(kLog2E, 1.44269504088896, 1e-10);
    EXPECT_DOUBLE_EQ(kDefaultCollapseThreshold, -3.2);
    EXPECT_EQ(kDefaultWindowSize, 8u);
    EXPECT_EQ(kVersionMajor, 2);
}

// ─── Unified dispatch tests ─────────────────────────────────────────────────

TEST(UnifiedDispatch, SingletonAndDetect) {
    auto& d1 = dispatch::UnifiedDispatch::instance();
    auto& d2 = dispatch::UnifiedDispatch::instance();
    EXPECT_EQ(&d1, &d2);

    d1.detect();
    auto& hw = d1.capabilities();
    EXPECT_TRUE(d1.is_available(Backend::SCALAR));
}

TEST(UnifiedDispatch, ComputeEntropy) {
    auto& d = dispatch::UnifiedDispatch::instance();
    d.detect();

    std::vector<double> logits(16, 0.0);
    double h = 0.0;
    auto result = d.compute_configurational_entropy(logits, h);
    EXPECT_TRUE(result);
    EXPECT_NEAR(h, 4.0, 1e-8);
}

TEST(UnifiedDispatch, BackendNames) {
    EXPECT_STREQ(dispatch::UnifiedDispatch::backend_name(Backend::SCALAR), "SCALAR");
    EXPECT_STREQ(dispatch::UnifiedDispatch::backend_name(Backend::AVX2), "AVX2");
    EXPECT_STREQ(dispatch::UnifiedDispatch::backend_name(Backend::AVX512), "AVX512");
    EXPECT_STREQ(dispatch::UnifiedDispatch::backend_name(Backend::NEON), "NEON");
    EXPECT_STREQ(dispatch::UnifiedDispatch::backend_name(Backend::AUTO), "AUTO");
}

#if defined(SHANNON_USE_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
TEST(NeonKernels, MatchesScalarConfigurational) {
    std::vector<double> logits(64);
    for (std::size_t i = 0; i < logits.size(); ++i) {
        logits[i] = std::sin(static_cast<double>(i) * 0.17) * 3.0;
    }
    double h_scalar = kernels::configurational_entropy_scalar(logits.data(), logits.size());
    double h_neon   = kernels::configurational_entropy_neon(logits.data(), logits.size());
    EXPECT_NEAR(h_scalar, h_neon, 1e-10);
}

TEST(NeonKernels, MatchesScalarProbs) {
    std::vector<double> probs = {0.05, 0.10, 0.15, 0.20, 0.25, 0.25};
    double h_scalar = kernels::entropy_from_probs_scalar(probs.data(), probs.size());
    double h_neon   = kernels::entropy_from_probs_neon(probs.data(), probs.size());
    EXPECT_NEAR(h_scalar, h_neon, 1e-12);
}

TEST(NeonKernels, MatchesScalarLogprobs) {
    std::vector<double> logprobs;
    for (double p : {0.1, 0.2, 0.3, 0.4}) {
        logprobs.push_back(std::log(p));
    }
    double h_scalar = kernels::entropy_from_logprobs_scalar(logprobs.data(), logprobs.size());
    double h_neon   = kernels::entropy_from_logprobs_neon(logprobs.data(), logprobs.size());
    EXPECT_NEAR(h_scalar, h_neon, 1e-12);
}

TEST(NeonKernels, OddLengthTail) {
    // Force scalar tail path (n not multiple of 2/4)
    std::vector<double> logits(17, 0.0);
    logits[3] = 1.5;
    double h_scalar = kernels::configurational_entropy_scalar(logits.data(), logits.size());
    double h_neon   = kernels::configurational_entropy_neon(logits.data(), logits.size());
    EXPECT_NEAR(h_scalar, h_neon, 1e-10);
}

TEST(UnifiedDispatch, SelectsNeonOnArm) {
    auto& d = dispatch::UnifiedDispatch::instance();
    d.detect();
    d.clear_override();

    EXPECT_TRUE(d.capabilities().has_neon);
    EXPECT_TRUE(d.is_available(Backend::NEON));
    EXPECT_TRUE(d.has_kernel(Backend::NEON, KernelType::CONFIGURATIONAL_ENTROPY));
    EXPECT_TRUE(d.has_kernel(Backend::NEON, KernelType::SHANNON_ENTROPY));
    EXPECT_TRUE(d.has_kernel(Backend::NEON, KernelType::LOGPROB_ENTROPY));

    Backend best = d.best_backend(KernelType::CONFIGURATIONAL_ENTROPY, /*n=*/256);
    // Prefer NEON over OpenMP for moderate n; GPU only if compiled+available
    EXPECT_TRUE(best == Backend::NEON || best == Backend::CUDA ||
                best == Backend::METAL || best == Backend::ROCM);

    std::vector<double> logits(32, 0.0);
    double h = 0.0;
    auto result = d.compute_configurational_entropy(logits, h, Backend::NEON);
    EXPECT_TRUE(result);
    EXPECT_EQ(result.used_backend, Backend::NEON);
    EXPECT_NEAR(h, 5.0, 1e-8);  // log2(32)
}

TEST(UnifiedDispatch, NeonOverrideProbsAndLogprobs) {
    auto& d = dispatch::UnifiedDispatch::instance();
    d.detect();

    std::vector<double> probs(8, 1.0 / 8.0);
    double h = 0.0;
    auto r = d.compute_entropy_from_probs(probs.data(), probs.size(), h, Backend::NEON);
    EXPECT_TRUE(r);
    EXPECT_EQ(r.used_backend, Backend::NEON);
    EXPECT_NEAR(h, 3.0, 1e-10);

    std::vector<double> lp(4, std::log(0.25));
    r = d.compute_entropy_from_logprobs(lp.data(), lp.size(), h, Backend::NEON);
    EXPECT_TRUE(r);
    EXPECT_EQ(r.used_backend, Backend::NEON);
    EXPECT_NEAR(h, 2.0, 1e-10);
}
#endif  // SHANNON_USE_NEON

TEST(HardwareDetect, NeonReportedOnArm) {
    auto& hw = hw::detect_hardware();
    auto summary = hw.summary();
#if defined(__aarch64__) || defined(__ARM_NEON)
    EXPECT_TRUE(hw.has_neon);
    EXPECT_NE(summary.find("NEON"), std::string::npos);
#endif
}

TEST(UnifiedDispatch, Override) {
    auto& d = dispatch::UnifiedDispatch::instance();
    d.clear_override();
    EXPECT_EQ(d.current_override(), Backend::AUTO);

    d.set_override(Backend::SCALAR);
    EXPECT_EQ(d.current_override(), Backend::SCALAR);

    d.clear_override();
}

// ─── Hardware detect tests ──────────────────────────────────────────────────

TEST(HardwareDetect, SummaryNotEmpty) {
    auto& hw = hw::detect_hardware();
    auto summary = hw.summary();
    EXPECT_FALSE(summary.empty());
    EXPECT_NE(summary.find("shannon::hw"), std::string::npos);
}

// ─── Collapse detector tests ────────────────────────────────────────────────

TEST(CollapseDetector, NoCollapseOnStableEntropy) {
    CollapseDetector det(8, -3.2);

    std::vector<double> logits(16, 0.0);
    for (int i = 0; i < 20; ++i) {
        auto r = det.add_logits(logits);
        if (i >= 8) {
            EXPECT_FALSE(r.collapsed);
        }
    }
}

TEST(CollapseDetector, DetectsSuddenCollapse) {
    CollapseDetector det(8, -3.2);

    std::vector<double> high_entropy(1024);
    for (std::size_t i = 0; i < 1024; ++i) {
        high_entropy[i] = static_cast<double>(i) * 0.01;
    }

    for (int i = 0; i < 8; ++i) {
        det.add_logits(high_entropy);
    }

    std::vector<double> collapsed(1024, -1000.0);
    collapsed[0] = 0.0;

    auto r = det.add_logits(collapsed);
    EXPECT_TRUE(r.collapsed);
    EXPECT_LT(r.entropy, 1.0);
}

TEST(CollapseDetector, CallbackFires) {
    bool callback_fired = false;
    CollapseDetector det(4, -2.0);
    det.set_callback([&](const CollapseResult&) {
        callback_fired = true;
    });

    std::vector<double> logits(16, 0.0);
    for (int i = 0; i < 4; ++i) det.add_logits(logits);

    std::vector<double> peak(16, -100.0);
    peak[0] = 0.0;
    det.add_logits(peak);

    EXPECT_TRUE(callback_fired);
}

TEST(CollapseDetector, ResetClearsState) {
    CollapseDetector det(4, -2.0);
    std::vector<double> logits(16, 0.0);
    for (int i = 0; i < 10; ++i) det.add_logits(logits);

    EXPECT_EQ(det.token_count(), 10u);
    det.reset();
    EXPECT_EQ(det.token_count(), 0u);
    EXPECT_TRUE(det.entropy_trace().empty());
}

TEST(CollapseDetector, SetWindowAndThreshold) {
    CollapseDetector det(8, -3.2);
    EXPECT_EQ(det.token_count(), 0u);

    std::vector<double> logits(16, 0.0);
    det.add_logits(logits);
    det.add_logits(logits);
    EXPECT_EQ(det.token_count(), 2u);

    det.set_window_size(4);
    det.set_threshold(-1.0);

    for (int i = 0; i < 4; ++i) det.add_logits(logits);

    std::vector<double> peak(16, -100.0);
    peak[0] = 0.0;
    auto r = det.add_logits(peak);
    EXPECT_TRUE(r.collapsed);

    det.reset();
    EXPECT_EQ(det.token_count(), 0u);
    EXPECT_TRUE(det.entropy_trace().empty());
}

TEST(CollapseDetector, StableVarianceSmallSpread) {
    CollapseDetector det(8, -3.2);

    double values[] = {10.0, 10.01, 9.99, 10.0, 10.01, 9.99, 10.0, 10.0};
    for (double v : values) {
        auto r = det.push_entropy(v);
        EXPECT_FALSE(std::isnan(r.window_std)) << "stddev is NaN at token " << r.token_index;
        EXPECT_GE(r.window_std, 0.0) << "stddev negative at token " << r.token_index;
    }

    // After 8 pushes the window contains {10.0, 10.01, 9.99, 10.0, 10.01, 9.99, 10.0, 10.0}
    // The 9th push(10.0) replaces position 0, window becomes {10.0, 10.01, 9.99, 10.0, 10.01, 9.99, 10.0, 10.0}
    // mean ≈ 10.0, stddev ≈ 0.007
    auto r = det.push_entropy(10.0);
    EXPECT_NEAR(r.window_mean, 10.0, 0.02);
    EXPECT_GT(r.window_std, 0.0);
    EXPECT_LT(r.window_std, 0.1);
}

TEST(CollapseDetector, VarianceZeroOnConstantInput) {
    CollapseDetector det(4, -3.2);

    for (int i = 0; i < 4; ++i) {
        auto r = det.push_entropy(5.0);
        if (i >= 3) {
            EXPECT_NEAR(r.window_std, 0.0, 1e-15);
            EXPECT_EQ(r.z_score, 0.0);
        }
    }
}

TEST(CollapseDetector, VarianceMatchesReference) {
    CollapseDetector det(4, -100.0);

    det.push_entropy(2.0);
    det.push_entropy(4.0);
    det.push_entropy(4.0);
    det.push_entropy(4.0);

    auto r = det.push_entropy(5.0);
    EXPECT_NEAR(r.window_mean, 4.25, 1e-10);
    // Welford sample variance (n-1): sum_sq_dev=0.75, var=0.75/3=0.25, stddev=0.5
    EXPECT_NEAR(r.window_std, 0.5, 1e-10);
}

TEST(CollapseDetector, NoFalsePositiveOnGradualDrift) {
    CollapseDetector det(8, -3.2);

    for (int i = 0; i < 20; ++i) {
        double h = 10.0 - 0.01 * static_cast<double>(i);
        auto r = det.push_entropy(h);
        if (i >= 8) {
            EXPECT_FALSE(r.collapsed) << "False positive at token " << i;
        }
    }
}

TEST(CollapseDetector, CollapseOnAbruptDrop) {
    CollapseDetector det(4, -2.0);

    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);

    auto r = det.push_entropy(2.0);
    EXPECT_TRUE(r.collapsed);
    EXPECT_LT(r.delta, -2.0);
    EXPECT_LT(r.z_score, -1.0);
}

TEST(CollapseDetector, ResetClearsCollapses) {
    CollapseDetector det(4, -2.0);

    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);
    auto r = det.push_entropy(2.0);
    EXPECT_TRUE(r.collapsed);

    det.reset();
    for (int i = 0; i < 4; ++i) det.push_entropy(10.0);
    r = det.push_entropy(10.0);
    EXPECT_FALSE(r.collapsed);
}

TEST(CollapseDetector, TraceCapped) {
    CollapseDetector det(4, -3.2);
    det.set_max_trace_size(10);

    for (int i = 0; i < 50; ++i) {
        det.push_entropy(static_cast<double>(i));
    }

    EXPECT_EQ(det.entropy_trace().size(), 10u);
    EXPECT_NEAR(det.entropy_trace().back(), 49.0, 1e-10);
}

TEST(CollapseDetector, TraceUnboundedByDefault) {
    CollapseDetector det(4, -3.2);

    for (int i = 0; i < 100; ++i) {
        det.push_entropy(static_cast<double>(i));
    }

    EXPECT_EQ(det.entropy_trace().size(), 100u);
}

// ─── Handrail tests ─────────────────────────────────────────────────────────

TEST(Handrail, LogsCollapses) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 10, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 1);
}

TEST(Handrail, EscalationCount) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 2;
    cfg.log_path = "/dev/null";
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    engine.evaluate(r);
    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 3);
}

TEST(Handrail, ThrottleAction) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::THROTTLE;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";
    cfg.shmem_path = "/tmp/shannon_test_throttle_" + std::to_string(::getpid());
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 1);
    EXPECT_EQ(engine.escalated_actions(), 1);

    ::unlink(("/tmp/shannon_test_throttle_" + std::to_string(::getpid())).c_str());
}

TEST(Handrail, KillActionNoCrash) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::KILL;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";
    cfg.monitored_pid = static_cast<pid_t>(999999999);
    cfg.cooldown_seconds = 100.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 1);
    EXPECT_EQ(engine.escalated_actions(), 1);
}

TEST(Handrail, SustainedThresholdOne) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::ALERT;
    cfg.on_sustained_collapse = HandrailAction::KILL;
    cfg.sustained_threshold = 1;
    cfg.log_path = "/dev/null";
    cfg.monitored_pid = static_cast<pid_t>(999999999);
    cfg.cooldown_seconds = 100.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 1);
    EXPECT_EQ(engine.escalated_actions(), 1);
}

TEST(Handrail, SustainedThresholdTwo) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::KILL;
    cfg.sustained_threshold = 2;
    cfg.log_path = "/dev/null";
    cfg.monitored_pid = static_cast<pid_t>(999999999);
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.escalated_actions(), 0);

    engine.evaluate(r);
    EXPECT_EQ(engine.escalated_actions(), 1);
    EXPECT_EQ(engine.total_collapses(), 2);
}

TEST(Handrail, ResetClearsState) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 2);

    engine.reset();
    EXPECT_EQ(engine.total_collapses(), 0);
    EXPECT_EQ(engine.escalated_actions(), 0);
}

TEST(Handrail, NonCollapseResetsConsecutive) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::LOG_ONLY;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 2;
    cfg.log_path = "/dev/null";

    HandrailEngine engine(std::move(cfg));

    CollapseResult collapsed{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };
    CollapseResult normal{
        .entropy = 8.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = 0.0, .z_score = 0.0, .collapsed = false,
        .token_index = 1, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(collapsed);
    engine.evaluate(normal);
    engine.evaluate(collapsed);

    EXPECT_EQ(engine.total_collapses(), 2);
}

TEST(Handrail, NoPidNoCrash) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::KILL;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    EXPECT_NO_THROW(engine.evaluate(r));
    EXPECT_EQ(engine.total_collapses(), 1);
    EXPECT_EQ(engine.escalated_actions(), 1);
}

TEST(Handrail, CoreDumpAction) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::COREDUMP;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";
    cfg.monitored_pid = static_cast<pid_t>(999999999);
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    engine.evaluate(r);
    EXPECT_EQ(engine.total_collapses(), 1);
    EXPECT_EQ(engine.escalated_actions(), 1);
}

TEST(Handrail, WebhookNoUrlNoCrash) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::WEBHOOK;
    cfg.on_sustained_collapse = HandrailAction::LOG_ONLY;
    cfg.sustained_threshold = 3;
    cfg.log_path = "/dev/null";
    cfg.cooldown_seconds = 0.0;

    HandrailEngine engine(std::move(cfg));

    CollapseResult r{
        .entropy = 1.0, .window_mean = 8.0, .window_std = 1.0,
        .delta = -7.0, .z_score = -7.0, .collapsed = true,
        .token_index = 0, .used_backend = Backend::SCALAR,
    };

    EXPECT_NO_THROW(engine.evaluate(r));
    EXPECT_EQ(engine.total_collapses(), 1);
}

// ─── Types tests ────────────────────────────────────────────────────────────

TEST(Types, BackendEnum) {
    EXPECT_EQ(static_cast<int>(Backend::SCALAR), 0);
    EXPECT_EQ(static_cast<int>(Backend::NEON), 5);
    EXPECT_EQ(static_cast<int>(Backend::AUTO), 255);
}

TEST(Types, HandrailActions) {
    HandrailConfig cfg;
    cfg.on_first_collapse = HandrailAction::ALERT;
    cfg.on_sustained_collapse = HandrailAction::KILL;
    EXPECT_EQ(cfg.on_first_collapse, HandrailAction::ALERT);
    EXPECT_EQ(cfg.on_sustained_collapse, HandrailAction::KILL);
}

TEST(Types, DispatchTelemetrySummary) {
    DispatchTelemetry tel;
    tel.backend = Backend::AVX2;
    tel.wall_time_ms = 1.5;
    tel.elements = 1000;
    tel.throughput_meps = 0.667;

    auto s = tel.summary();
    EXPECT_FALSE(s.empty());
    EXPECT_NE(s.find("AVX2"), std::string::npos);
    EXPECT_NE(s.find("1.5"), std::string::npos);
}

TEST(Types, DispatchResultBoolConversion) {
    DispatchResult ok;
    ok.error = DispatchError::OK;
    EXPECT_TRUE(static_cast<bool>(ok));

    DispatchResult fail;
    fail.error = DispatchError::NO_BACKEND;
    EXPECT_FALSE(static_cast<bool>(fail));
}

// ─── TerminalAgent tests ────────────────────────────────────────────────────

TEST(TerminalAgent, ProcessLogits) {
    AgentConfig config;
    config.quiet = true;
    TerminalAgent agent(std::move(config));

    std::vector<double> uniform(16, 0.0);
    auto r = agent.process_logits(uniform);
    EXPECT_GT(r.entropy, 0.0);
    EXPECT_EQ(agent.tokens_processed(), 1u);

    for (int i = 0; i < 5; ++i) {
        agent.process_logits(uniform);
    }
    EXPECT_EQ(agent.tokens_processed(), 6u);
}

TEST(TerminalAgent, StopBreaksStdin) {
    AgentConfig config;
    config.quiet = true;
    TerminalAgent agent(std::move(config));

    agent.stop();
    EXPECT_FALSE(agent.detector().token_count() > 0);
}

TEST(TerminalAgent, ResetClears) {
    AgentConfig config;
    config.quiet = true;
    TerminalAgent agent(std::move(config));

    std::vector<double> logits(16, 0.0);
    agent.process_logits(logits);
    agent.process_logits(logits);
    EXPECT_EQ(agent.tokens_processed(), 2u);

    agent.reset();
    EXPECT_EQ(agent.tokens_processed(), 0u);
}

// ─── StdinIngester tests ────────────────────────────────────────────────────

TEST(StdinIngester, ParseValidAndInvalid) {
    shannon::ingest::StdinIngester parser("logits", InputFormat::LOGITS);

    shannon::ingest::TokenData data;
    EXPECT_TRUE(parser.parse_jsonl_line(
        R"({"logits": [0.1, 0.2, 0.3, 0.4]})", data));
    EXPECT_EQ(data.logits.size(), 4u);
    EXPECT_NEAR(data.logits[0], 0.1, 1e-10);

    EXPECT_FALSE(parser.parse_jsonl_line("", data));
    EXPECT_FALSE(parser.parse_jsonl_line("# comment", data));
    EXPECT_FALSE(parser.parse_jsonl_line("{}", data));
    EXPECT_FALSE(parser.parse_jsonl_line(
        R"({"other_field": [1.0, 2.0]})", data));
}

TEST(StdinIngester, RejectsNonFiniteTokens) {
    shannon::ingest::StdinIngester parser("logits", InputFormat::LOGITS);
    shannon::ingest::TokenData data;

    // NaN / Inf / -Inf anywhere in the array → token skipped (returns false),
    // never fed to the kernels (H=0.0 would be a false collapse alarm).
    EXPECT_FALSE(parser.parse_jsonl_line(
        R"({"logits": [0.1, nan, 0.3]})", data));
    EXPECT_FALSE(parser.parse_jsonl_line(
        R"({"logits": [inf, 0.2, 0.3]})", data));
    EXPECT_FALSE(parser.parse_jsonl_line(
        R"({"logits": [0.1, 0.2, -inf]})", data));

    // A clean line still parses after the rejected ones.
    EXPECT_TRUE(parser.parse_jsonl_line(
        R"({"logits": [1.0, 2.0, 3.0]})", data));
    EXPECT_EQ(data.logits.size(), 3u);
}

TEST(StdinIngester, LocaleIndependentDecimalParsing) {
    // from_chars always reads '.' as the decimal separator regardless of the
    // C locale, so fractional values parse consistently.
    shannon::ingest::StdinIngester parser("logits", InputFormat::LOGITS);
    shannon::ingest::TokenData data;
    ASSERT_TRUE(parser.parse_jsonl_line(
        R"({"logits": [3.14, 2.71, 0.5]})", data));
    ASSERT_EQ(data.logits.size(), 3u);
    EXPECT_NEAR(data.logits[0], 3.14, 1e-12);
    EXPECT_NEAR(data.logits[1], 2.71, 1e-12);
    EXPECT_NEAR(data.logits[2], 0.5, 1e-12);
}

// ─── TurboQuant tests ───────────────────────────────────────────────────────

TEST(TurboQuant, BuildCodebook) {
    std::vector<double> vals = {0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0};
    auto cb = quant::build_codebook(vals.data(), vals.size(), 2);
    EXPECT_EQ(cb.bits, 2);
    EXPECT_EQ(cb.levels, 4);
    EXPECT_EQ(cb.centroids.size(), 4u);
}

TEST(TurboQuant, QuantizeDequantize) {
    std::vector<double> vals;
    for (int i = 0; i < 100; ++i) {
        vals.push_back(std::sin(i * 0.1) * 5.0);
    }

    auto cb = quant::build_codebook(vals.data(), vals.size(), 4);
    auto qd = quant::quantize(vals.data(), vals.size(), cb);
    EXPECT_EQ(qd.n, 100u);

    auto recovered = quant::dequantize(qd);
    EXPECT_EQ(recovered.size(), 100u);

    double mse = 0.0;
    for (std::size_t i = 0; i < vals.size(); ++i) {
        double err = vals[i] - recovered[i];
        mse += err * err;
    }
    mse /= static_cast<double>(vals.size());
    EXPECT_LT(mse, 2.0);
}

TEST(TurboQuant, EntropyBounded) {
    std::vector<double> uniform(16, 0.0);
    for (int i = 0; i < 16; ++i) uniform[i] = static_cast<double>(i);
    double h_full = kernels::configurational_entropy_scalar(uniform.data(), 16);
    double h_quant = quant::quantized_entropy(uniform.data(), 16, 4);

    EXPECT_GT(h_full, 0.0);
    EXPECT_GT(h_quant, 0.0);
    EXPECT_LE(h_quant, 4.0);
}
