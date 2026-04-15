// handrail.cpp — Failsafe handrail engine for Shannon 2.0
//
// Evaluates collapse, expansion, and oscillation events with
// escalation and cooldown logic.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/handrail.hpp"

#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>

#include <csignal>
#include <signal.h>
#include <sys/types.h>
#include <unistd.h>

namespace shannon {

HandrailEngine::HandrailEngine(HandrailConfig cfg)
    : cfg_(std::move(cfg))
    , last_action_time_(std::chrono::steady_clock::now() -
                        std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                            std::chrono::duration<double>(cfg_.cooldown_seconds + 1.0))) {}

void HandrailEngine::evaluate(const CollapseResult& result) {
    if (result.oscillating) {
        total_oscillations_.fetch_add(1, std::memory_order_relaxed);
        log_event("OSCILLATION", result);
        execute_action(cfg_.on_oscillation, result);
        consecutive_collapses_.store(0, std::memory_order_relaxed);
        return;
    }

    if (result.expanded) {
        total_expansions_.fetch_add(1, std::memory_order_relaxed);
        consecutive_collapses_.store(0, std::memory_order_relaxed);
        log_event("EXPANSION", result);
        execute_action(cfg_.on_expansion, result);
        return;
    }

    if (!result.collapsed) {
        consecutive_collapses_.store(0, std::memory_order_relaxed);
        return;
    }

    total_collapses_.fetch_add(1, std::memory_order_relaxed);
    consecutive_collapses_.fetch_add(1, std::memory_order_relaxed);

    log_event("COLLAPSE", result);

    int cc = consecutive_collapses_.load(std::memory_order_relaxed);

    if (cc == 1) {
        execute_action(cfg_.on_first_collapse, result);
    } else if (cc >= cfg_.sustained_threshold) {
        execute_action(cfg_.on_sustained_collapse, result);
    }
}

void HandrailEngine::reset() {
    consecutive_collapses_.store(0, std::memory_order_relaxed);
    total_collapses_.store(0, std::memory_order_relaxed);
    total_expansions_.store(0, std::memory_order_relaxed);
    total_oscillations_.store(0, std::memory_order_relaxed);
    escalated_.store(0, std::memory_order_relaxed);
}

int HandrailEngine::total_collapses() const {
    return total_collapses_.load(std::memory_order_relaxed);
}

int HandrailEngine::total_expansions() const {
    return total_expansions_.load(std::memory_order_relaxed);
}

int HandrailEngine::total_oscillations() const {
    return total_oscillations_.load(std::memory_order_relaxed);
}

int HandrailEngine::escalated_actions() const {
    return escalated_.load(std::memory_order_relaxed);
}

bool HandrailEngine::cooldown_ok() const {
    std::lock_guard<std::mutex> lock(action_mutex_);
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration<double>(now - last_action_time_).count();
    return elapsed >= cfg_.cooldown_seconds;
}

void HandrailEngine::log_event(const char* event_type, const CollapseResult& result) {
    std::FILE* fp = nullptr;
    const bool is_stderr = (cfg_.log_path.empty() || cfg_.log_path == "/dev/stderr");

    if (is_stderr) {
        fp = stderr;
    } else {
        fp = std::fopen(cfg_.log_path.c_str(), "a");
    }

    if (!fp) return;

    std::fprintf(fp,
        "[SHANNON HANDRAIL] %s at token %zu: "
        "entropy=%.4f bits, delta=%.4f, z=%.4f, backend=%d\n",
        event_type,
        result.token_index,
        result.entropy,
        result.delta,
        result.z_score,
        static_cast<int>(result.used_backend));

    if (!is_stderr) std::fclose(fp);
}

void HandrailEngine::send_signal(int sig, std::optional<pid_t> pid) {
    if (!pid.has_value()) return;
    ::kill(pid.value(), sig);
}

void HandrailEngine::execute_action(HandrailAction action, const CollapseResult& result) {
    if (action != HandrailAction::LOG_ONLY && !cooldown_ok()) return;

    switch (action) {
    case HandrailAction::LOG_ONLY:
        break;

    case HandrailAction::ALERT:
        send_signal(SIGUSR1, cfg_.monitored_pid);
        escalated_.fetch_add(1, std::memory_order_relaxed);
        break;

    case HandrailAction::THROTTLE:
        if (!cfg_.shmem_path.empty()) {
            std::ofstream ofs(cfg_.shmem_path, std::ios::trunc);
            if (ofs) ofs << "THROTTLE\n";
        }
        escalated_.fetch_add(1, std::memory_order_relaxed);
        break;

    case HandrailAction::KILL:
        send_signal(SIGTERM, cfg_.monitored_pid);
        escalated_.fetch_add(1, std::memory_order_relaxed);
        break;

    case HandrailAction::COREDUMP:
        send_signal(SIGABRT, cfg_.monitored_pid);
        escalated_.fetch_add(1, std::memory_order_relaxed);
        break;

    case HandrailAction::WEBHOOK:
        if (!cfg_.webhook_url.empty()) {
            fire_webhook(cfg_.webhook_url, result);
        }
        escalated_.fetch_add(1, std::memory_order_relaxed);
        break;

    case HandrailAction::CALLBACK:
        break;
    }

    if (action != HandrailAction::LOG_ONLY) {
        std::lock_guard<std::mutex> lock(action_mutex_);
        last_action_time_ = std::chrono::steady_clock::now();
    }
}

void HandrailEngine::fire_webhook(const std::string& url, const CollapseResult& result) {
    const char* event_str = "none";
    if (result.collapsed) event_str = "collapse";
    else if (result.expanded) event_str = "expansion";
    else if (result.oscillating) event_str = "oscillation";

    std::string json = "{\"event\":\"";
    json += event_str;
    json += "\",\"entropy\":";
    json += std::to_string(result.entropy);
    json += ",\"token_index\":";
    json += std::to_string(result.token_index);
    json += ",\"delta\":";
    json += std::to_string(result.delta);
    json += ",\"z_score\":";
    json += std::to_string(result.z_score);
    json += "}";

    static std::atomic<bool> sigchld_installed{false};
    if (!sigchld_installed.exchange(true)) {
        struct ::sigaction sa{};
        sa.sa_handler = SIG_IGN;
        sa.sa_flags = SA_NOCLDWAIT;
        ::sigaction(SIGCHLD, &sa, nullptr);
        sigchld_installed = true;
    }

    pid_t pid = ::fork();
    if (pid < 0) return;
    if (pid == 0) {
        ::close(STDIN_FILENO);
        ::close(STDOUT_FILENO);
        ::close(STDERR_FILENO);
        const char* argv[] = {
            "curl", "-s", "-X", "POST",
            "-H", "Content-Type: application/json",
            "-d", json.c_str(),
            url.c_str(),
            nullptr
        };
        ::execvp("curl", const_cast<char* const*>(argv));
        ::_exit(127);
    }
}

}  // namespace shannon
