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

#include <atomic>
#include <chrono>
#include <mutex>
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
    std::atomic<int> consecutive_collapses_{0};
    std::atomic<int> total_collapses_{0};
    std::atomic<int> escalated_{0};
    mutable std::mutex action_mutex_;
    std::chrono::steady_clock::time_point last_action_time_;

    void execute_action(HandrailAction action, const CollapseResult& result);
    bool cooldown_ok() const;
    void log_collapse(const CollapseResult& result);
    void send_signal(int sig, std::optional<pid_t> pid);
    void fire_webhook(const std::string& url, const CollapseResult& result);
};

}  // namespace shannon
