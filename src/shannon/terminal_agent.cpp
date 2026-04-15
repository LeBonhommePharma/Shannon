// terminal_agent.cpp — Shannon terminal agent implementation
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/terminal_agent.hpp"

#include <cstdio>
#include <iostream>
#include <memory>

namespace shannon {

TerminalAgent::TerminalAgent(AgentConfig config)
    : config_(std::move(config))
    , detector_(config_.window_size, config_.threshold_bits)
    , handrail_(config_.handrail)
{
    detector_.set_callback([this](const CollapseResult& r) {
        on_collapse(r);
    });
}

int TerminalAgent::run() {
    running_.store(true, std::memory_order_relaxed);

    dispatch::UnifiedDispatch::instance().detect();

    if (!config_.quiet) {
        auto report = dispatch::UnifiedDispatch::instance().hardware_report();
        std::fprintf(stderr, "%s", report.c_str());
        std::fprintf(stderr, "[shannon] Monitoring with window=%zu, threshold=%.1f bits\n",
            config_.window_size, config_.threshold_bits);
    }

    int exit_code = 0;
    switch (config_.stream_mode) {
    case StreamMode::STDIN_PIPE:
        exit_code = run_stdin();
        break;
    case StreamMode::UNIX_SOCKET:
        exit_code = run_socket();
        break;
    case StreamMode::SHARED_MEMORY:
        exit_code = run_shmem();
        break;
    }

    if (!config_.quiet) {
        std::fprintf(stderr, "[shannon] Done. %zu tokens, %d collapses, %d expansions, %d oscillations\n",
            tokens_processed_, handrail_.total_collapses(),
            handrail_.total_expansions(), handrail_.total_oscillations());
    }

    return exit_code;
}

CollapseResult TerminalAgent::process_logits(const double* logits, std::size_t n) {
    auto result = detector_.add_logits(logits, n);
    ++tokens_processed_;
    return result;
}

CollapseResult TerminalAgent::process_logits(std::span<const double> logits) {
    return process_logits(logits.data(), logits.size());
}

void TerminalAgent::reset() {
    detector_.reset();
    handrail_.reset();
    tokens_processed_ = 0;
}

void TerminalAgent::stop() {
    running_.store(false, std::memory_order_relaxed);
    if (socket_ingester_) socket_ingester_->stop();
    if (shmem_ingester_) shmem_ingester_->stop();
}

const CollapseDetector& TerminalAgent::detector() const noexcept {
    return detector_;
}

const HandrailEngine& TerminalAgent::handrail() const noexcept {
    return handrail_;
}

std::size_t TerminalAgent::tokens_processed() const noexcept {
    return tokens_processed_;
}

int TerminalAgent::run_stdin() {
    ingest::StdinIngester ingester(config_.jsonl_field, config_.input_format);

    while (running_.load(std::memory_order_relaxed)) {
        bool ok = ingester.read_one([this](const ingest::TokenData& data) {
            CollapseResult result;
            switch (data.format) {
            case InputFormat::LOGITS:
                result = detector_.add_logits(data.logits);
                break;
            case InputFormat::PROBS:
                result = detector_.add_probs(data.probs);
                break;
            case InputFormat::LOGPROBS:
                result = detector_.add_logprobs(data.logprobs);
                break;
            default:
                result = detector_.add_logits(data.logits);
                break;
            }
            ++tokens_processed_;

            if (!config_.quiet && config_.verbose) {
                const char* tag = "";
                if (result.oscillating)    tag = " ** OSCILLATION **";
                else if (result.expanded)  tag = " ** EXPANSION **";
                else if (result.collapsed) tag = " ** COLLAPSE **";
                std::fprintf(stderr,
                    "[shannon] token %zu: H=%.4f bits, delta=%.4f, z=%.4f%s\n",
                    result.token_index,
                    result.entropy,
                    result.delta,
                    result.z_score,
                    tag);
            }
        });

        if (!ok) break;
    }

    return (handrail_.total_collapses() > 0 || handrail_.total_oscillations() > 0) ? 1 : 0;
}

int TerminalAgent::run_socket() {
    socket_ingester_ = std::make_unique<ingest::SocketIngester>(config_.socket_path);

    socket_ingester_->listen([this](const ingest::TokenData& data) {
        auto result = detector_.add_logits(data.logits);
        ++tokens_processed_;

        if (!config_.quiet && config_.verbose) {
                const char* tag = "";
                if (result.collapsed) tag = " ** COLLAPSE **";
                else if (result.expanded) tag = " ** EXPANSION **";
                std::fprintf(stderr,
                    "[shannon] token %zu: H=%.4f bits%s\n",
                    result.token_index, result.entropy, tag);
            }
    });

    socket_ingester_.reset();
    return (handrail_.total_collapses() > 0 || handrail_.total_oscillations() > 0) ? 1 : 0;
}

int TerminalAgent::run_shmem() {
    shmem_ingester_ = std::make_unique<ingest::ShmemIngester>(config_.shmem_name);

    if (!shmem_ingester_->open()) {
        std::fprintf(stderr, "[shannon] Failed to open shared memory: %s\n",
            config_.shmem_name.c_str());
        shmem_ingester_.reset();
        return 2;
    }

    shmem_ingester_->poll([this](const ingest::TokenData& data) {
        auto result = detector_.add_logits(data.logits);
        ++tokens_processed_;

        if (!config_.quiet && config_.verbose) {
                const char* tag = "";
                if (result.collapsed) tag = " ** COLLAPSE **";
                else if (result.expanded) tag = " ** EXPANSION **";
                std::fprintf(stderr,
                    "[shannon] token %zu: H=%.4f bits%s\n",
                    result.token_index, result.entropy, tag);
            }
    });

    shmem_ingester_->close();
    shmem_ingester_.reset();
    return (handrail_.total_collapses() > 0 || handrail_.total_oscillations() > 0) ? 1 : 0;
}

void TerminalAgent::on_collapse(const CollapseResult& result) {
    handrail_.evaluate(result);
}

}  // namespace shannon