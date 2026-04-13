// handrail.hpp — Failsafe handrail engine for Shannon 2.0
//
// Evaluates collapse events and executes configured failsafe actions:
// alert, throttle, kill, coredump, webhook, or user callback.
// Supports escalation: first collapse → on_first_collapse action,
// N consecutive collapses → on_sustained_collapse action (with cooldown).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/types.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>

namespace shannon {

class HandrailEngine {
public:
    explicit HandrailEngine(HandrailConfig cfg);

    void evaluate(const CollapseResult& result);
    void reset();

    int total_collapses()    const;
    int escalated_actions()  const;

private:
    HandrailConfig cfg_;
    int consecutive_collapses_ = 0;
    int total_collapses_       = 0;
    int escalated_             = 0;
    std::chrono::steady_clock::time_point last_action_time_;

    void execute_action(HandrailAction action, const CollapseResult& result);
    bool cooldown_ok() const;
    void log_collapse(const CollapseResult& result);
    void send_signal(int sig, const std::string& pid);
};

}  // namespace shannon
