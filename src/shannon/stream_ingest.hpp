// stream_ingest.hpp — Token stream ingestion for Shannon 2.0
//
// Three ingestion modes:
//   1. stdin pipe (JSONL) — parse logits/probs/logprobs from JSON lines
//   2. Unix domain socket — low-latency local IPC
//   3. Shared memory — zero-copy, <100ns latency
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/types.hpp"

#include <atomic>
#include <cstddef>
#include <filesystem>
#include <functional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace shannon::ingest {

// Parsed token data from one step of the stream
struct TokenData {
    std::size_t token_index = 0;
    std::vector<double> logits;     // unnormalized log-weights (preferred)
    std::vector<double> probs;      // probability distribution
    std::vector<double> logprobs;   // log-probabilities
    InputFormat format = InputFormat::LOGITS;
};

// Callback for each parsed token
using TokenCallback = std::function<void(const TokenData&)>;

// ─── JSONL stdin pipe ingestion ──────────────────────────────────────────────

class StdinIngester {
public:
    explicit StdinIngester(
        std::string field = "logits",
        InputFormat format = InputFormat::LOGITS);

    // Read one JSONL line, parse, invoke callback. Returns false on EOF.
    bool read_one(TokenCallback cb);

    // Read all lines until EOF
    void read_all(TokenCallback cb);

    // Parse a single JSONL line into TokenData
    bool parse_jsonl_line(std::string_view line, TokenData& out);

private:
    std::string field_;
    InputFormat format_;
    std::size_t token_index_ = 0;
};

// ─── Unix domain socket ingestion ────────────────────────────────────────────

class SocketIngester {
public:
    explicit SocketIngester(std::filesystem::path socket_path);

    // Connect and start reading. Blocks until disconnected.
    void listen(TokenCallback cb);

    // Read a single message (non-blocking if timeout_ms > 0)
    bool read_one(TokenCallback cb, int timeout_ms = 0);

    void stop();
    void close();

private:
    std::filesystem::path path_;
    int fd_ = -1;
    std::atomic<bool> running_{false};
    StdinIngester parser_{"logits", InputFormat::LOGITS};
    std::string leftover_;

    bool connect();
};

// ─── Shared memory ingestion (zero-copy) ─────────────────────────────────────

class ShmemIngester {
public:
    explicit ShmemIngester(std::string name, std::size_t max_tokens = 128000);

    // Open existing shared memory region
    bool open();

    // Read the current token vector from shared memory
    // Returns span pointing into the mapped region (zero-copy)
    std::span<const double> read_current();

    // Poll for new tokens and invoke callback
    void poll(TokenCallback cb, int poll_interval_us = 100);

    void stop();
    void close();

private:
    std::string name_;
    std::size_t max_tokens_;
    int fd_ = -1;
    void* mapped_ = nullptr;
    std::size_t mapped_size_ = 0;
    std::size_t last_seen_index_ = 0;
    std::atomic<bool> stop_requested_{false};
};

}  // namespace shannon::ingest
