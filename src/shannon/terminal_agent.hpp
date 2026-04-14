// terminal_agent.hpp — Shannon terminal agent (like Claude Code)
//
// The thermodynamic physicochemical referee that sits on top of any LLM.
// Reads token streams, computes entropy, detects collapse, and fires
// handrails when the monitored agent is deceiving while appearing to
// do its task.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/collapse_detector.hpp"
#include "shannon/handrail.hpp"
#include "shannon/stream_ingest.hpp"
#include "shannon/types.hpp"
#include "shannon/config.hpp"

#include <atomic>
#include <chrono>
#include <cstddef>
#include <memory>
#include <string>

namespace shannon {

struct AgentConfig {
    // Entropy detection
    std::size_t window_size    = kDefaultWindowSize;
    double threshold_bits      = kDefaultCollapseThreshold;

    // Input stream
    StreamMode stream_mode     = StreamMode::STDIN_PIPE;
    InputFormat input_format   = InputFormat::LOGITS;
    std::string jsonl_field    = "logits";
    std::string socket_path;
    std::string shmem_name;

    // Handrails
    HandrailConfig handrail;

    // Output
    bool verbose               = true;
    bool quiet                  = false;  // exit-code-only mode
    std::string log_path       = "/dev/stderr";
};

class TerminalAgent {
public:
    explicit TerminalAgent(AgentConfig config);

    // Main entry: run the agent loop (blocks until stream ends)
    int run();

    // Process a single token step (for programmatic use)
    CollapseResult process_logits(const double* logits, std::size_t n);
    CollapseResult process_logits(std::span<const double> logits);

    // Lifecycle
    void reset();
    void stop();

    // Accessors
    const CollapseDetector& detector() const noexcept;
    const HandrailEngine& handrail() const noexcept;
    std::size_t tokens_processed() const noexcept;

private:
    AgentConfig config_;
    CollapseDetector detector_;
    HandrailEngine handrail_;
    std::size_t tokens_processed_ = 0;
    std::atomic<bool> running_{false};
    std::unique_ptr<ingest::SocketIngester> socket_ingester_;
    std::unique_ptr<ingest::ShmemIngester> shmem_ingester_;

    int run_stdin();
    int run_socket();
    int run_shmem();

    void on_collapse(const CollapseResult& result);
};

}  // namespace shannon
