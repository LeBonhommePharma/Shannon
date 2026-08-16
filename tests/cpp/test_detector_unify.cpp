// test_detector_unify.cpp — v1 and v2 CollapseDetector in one TU
//
// Product name `shannon::CollapseDetector` is v2 (Welford n−1, UnifiedDispatch).
// Legacy `shannon::v1::CollapseDetector` keeps population variance and
// collapse-only callbacks. Both implementations must remain distinct.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include <gtest/gtest.h>

#include "shannon.hpp"
#include "shannon/collapse_detector.hpp"
#include "shannon/terminal_agent.hpp"

#include <cmath>
#include <type_traits>
#include <vector>

TEST(DetectorUnify, V1AndV2AreDistinctTypes) {
    static_assert(!std::is_same_v<shannon::v1::CollapseDetector, shannon::CollapseDetector>);
    static_assert(!std::is_same_v<shannon::v1::CollapseResult, shannon::CollapseResult>);
}

TEST(DetectorUnify, SameEntropyStreamDisagreesOnVariance) {
    shannon::v1::CollapseDetector v1(4, -100.0);
    shannon::CollapseDetector v2(4, -100.0);

    const double stream[] = {2.0, 4.0, 4.0, 4.0, 5.0};
    shannon::v1::CollapseResult r1{};
    shannon::CollapseResult r2{};
    for (double h : stream) {
        r1 = v1.push_entropy(h);
        r2 = v2.push_entropy(h);
        EXPECT_DOUBLE_EQ(r1.entropy, r2.entropy);
        EXPECT_DOUBLE_EQ(r1.token_index, r2.token_index);
    }
    EXPECT_NEAR(r1.window_mean, 4.25, 1e-10);
    EXPECT_NEAR(r2.window_mean, 4.25, 1e-10);
    EXPECT_NEAR(r1.window_std, std::sqrt(0.1875), 1e-10);
    EXPECT_NEAR(r2.window_std, 0.5, 1e-10);
    EXPECT_GT(std::abs(r1.window_std - r2.window_std), 1e-6);
}

TEST(DetectorUnify, BothDetectAbruptCollapse) {
    shannon::v1::CollapseDetector v1(4, -2.0);
    shannon::CollapseDetector v2(4, -2.0, +3.2, 5);

    for (int i = 0; i < 4; ++i) {
        v1.push_entropy(10.0);
        v2.push_entropy(10.0);
    }
    auto a = v1.push_entropy(2.0);
    auto b = v2.push_entropy(2.0);
    EXPECT_TRUE(a.collapsed);
    EXPECT_TRUE(b.collapsed);
    EXPECT_FALSE(b.expanded);
}

TEST(DetectorUnify, V2KeepsExpansionOscillationSurface) {
    shannon::CollapseDetector v2(4, -2.0, +2.0, 5);
    EXPECT_EQ(v2.oscillation_window(), 5u);
    for (int i = 0; i < 4; ++i) {
        v2.push_entropy(1.0);
    }
    auto up = v2.push_entropy(10.0);
    EXPECT_TRUE(up.expanded);
    EXPECT_FALSE(up.collapsed);
}

TEST(DetectorUnify, AgentOscillationWindowIsApplied) {
    shannon::AgentConfig config;
    config.quiet = true;
    config.oscillation_window = 9;
    shannon::TerminalAgent agent(std::move(config));
    EXPECT_EQ(agent.detector().oscillation_window(), 9u);
}
