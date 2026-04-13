// handrail.cpp — Failsafe handrail engine for Shannon 2.0
//
// Evaluates collapse events and executes configured failsafe actions
// with escalation and cooldown logic.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/handrail.hpp"

#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <thread>

// For signal dispatch
#include <csignal>
#include <sys/types.h>
#include <unistd.h>

namespace shannon {

HandrailEngine::HandrailEngine(HandrailConfig cfg)
    : cfg_(std::move(cfg))
    , last_action_time_(std::chrono::steady_clock::now() -
                        std::chrono::duration<double>(cfg_.cooldown_seconds + 1.0)) {}

void HandrailEngine::evaluate(const CollapseResult& result) {
    if (!result.collapsed) {
        consecutive_collapses_ = 0;
        return;
    }

    ++total_collapses_;
    ++consecutive_collapses_;

    log_collapse(result);

    if (consecutive_collapses_ == 1) {
        execute_action(cfg_.on_first_collapse, result);
    }

    if (consecutive_collapses_ >= cfg_.sustained_threshold) {
        execute_action(cfg_.on_sustained_collapse, result);
    }
}

void HandrailEngine::reset() {
    consecutive_collapses_ = 0;
    total_collapses_ = 0;
    escalated_ = 0;
}

int HandrailEngine::total_collapses() const {
    return total_collapses_;
}

int HandrailEngine::escalated_actions() const {
    return escalated_;
}

bool HandrailEngine::cooldown_ok() const {
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration<double>(now - last_action_time_).count();
    return elapsed >= cfg_.cooldown_seconds;
}

void HandrailEngine::log_collapse(const CollapseResult& result) {
    std::FILE* fp = nullptr;
    const bool is_stderr = (cfg_.log_path.empty() || cfg_.log_path == "/dev/stderr");

    if (is_stderr) {
        fp = stderr;
    } else {
        fp = std::fopen(cfg_.log_path.c_str(), "a");
    }

    if (!fp) return;

    std::fprintf(fp,
        "[SHANNON HANDRAIL] collapse #%d at token %zu: "
        "entropy=%.4f bits, delta=%.4f, z=%.4f, backend=%d\n",
        total_collapses_,
        result.token_index,
        result.entropy,
        result.delta,
        result.z_score,
        static_cast<int>(result.used_backend));

    if (!is_stderr) std::fclose(fp);
}

void HandrailEngine::send_signal(int sig, const std::string& pid_str) {
    if (pid_str.empty()) return;
    try {
        pid_t pid = static_cast<pid_t>(std::stoi(pid_str));
        ::kill(pid, sig);
    } catch (...) {
        // Invalid PID — ignore
    }
}

void HandrailEngine::execute_action(HandrailAction action, const CollapseResult& result) {
    // Only escalate if cooldown has elapsed (except LOG_ONLY)
    if (action != HandrailAction::LOG_ONLY && !cooldown_ok()) return;

    switch (action) {
    case HandrailAction::LOG_ONLY:
        // Already logged in evaluate()
        break;

    case HandrailAction::ALERT:
        send_signal(SIGUSR1, cfg_.monitored_pid);
        ++escalated_;
        break;

    case HandrailAction::THROTTLE:
        // Write throttle flag to shared memory path (if configured)
        if (!cfg_.shmem_path.empty()) {
            std::ofstream ofs(cfg_.shmem_path, std::ios::trunc);
            if (ofs) ofs << "THROTTLE\n";
        }
        ++escalated_;
        break;

    case HandrailAction::KILL:
        send_signal(SIGTERM, cfg_.monitored_pid);
        ++escalated_;
        break;

    case HandrailAction::COREDUMP:
        send_signal(SIGABRT, cfg_.monitored_pid);
        ++escalated_;
        break;

    case HandrailAction::WEBHOOK:
        // Fire-and-forget HTTP POST (simple system() call)
        if (!cfg_.webhook_url.empty()) {
            std::ostringstream cmd;
            cmd << "curl -s -X POST -H 'Content-Type: application/json' "
                << "-d '{\"collapsed\":true,\"entropy\":" << result.entropy
                << ",\"token_index\":" << result.token_index
                << ",\"delta\":" << result.delta
                << ",\"z_score\":" << result.z_score
                << "}' '" << cfg_.webhook_url << "' >/dev/null 2>&1 &";
            std::system(cmd.str().c_str());
        }
        ++escalated_;
        break;

    case HandrailAction::CALLBACK:
        // Handled externally via CollapseCallback set on the detector
        break;
    }

    if (action != HandrailAction::LOG_ONLY) {
        last_action_time_ = std::chrono::steady_clock::now();
    }
}

}  // namespace shannon
