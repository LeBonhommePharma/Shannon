// stream_ingest.cpp — Token stream ingestion implementations
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/stream_ingest.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>

// Shared memory / socket headers
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

namespace shannon::ingest {

// ─── Minimal JSON parsing (no external dependency) ───────────────────────────

static std::vector<double> parse_json_array(std::string_view s) {
    std::vector<double> result;
    auto start = s.find('[');
    auto end = s.rfind(']');
    if (start == std::string_view::npos || end == std::string_view::npos) return result;

    std::string content(s.substr(start + 1, end - start - 1));
    std::size_t pos = 0;

    while (pos < content.size()) {
        while (pos < content.size() && (content[pos] == ' ' || content[pos] == ',' ||
               content[pos] == '\t' || content[pos] == '\n' || content[pos] == '\r')) {
            ++pos;
        }
        if (pos >= content.size()) break;

        char* endptr = nullptr;
        double val = std::strtod(content.data() + pos, &endptr);
        if (endptr == content.data() + pos) break;

        result.push_back(val);
        pos = static_cast<std::size_t>(endptr - content.data());
    }

    return result;
}

static std::string_view extract_field(std::string_view json, std::string_view field) {
    std::string needle = "\"";
    needle += field;
    needle += "\"";
    auto pos = json.find(needle);
    if (pos == std::string_view::npos) return {};

    // Skip to the value after the colon
    pos = json.find(':', pos + needle.size());
    if (pos == std::string_view::npos) return {};
    ++pos;

    // Skip whitespace
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) ++pos;

    // The value is either a number, string, or array
    if (pos >= json.size()) return {};

    if (json[pos] == '[') {
        auto end = json.find(']', pos);
        if (end == std::string_view::npos) return {};
        return json.substr(pos, end - pos + 1);
    }

    // Simple number or string value
    auto end = pos;
    while (end < json.size() && json[end] != ',' && json[end] != '}' && json[end] != '\n') {
        ++end;
    }
    return json.substr(pos, end - pos);
}

// ─── StdinIngester ───────────────────────────────────────────────────────────

StdinIngester::StdinIngester(std::string field, InputFormat format)
    : field_(std::move(field)), format_(format) {}

bool StdinIngester::parse_jsonl_line(std::string_view line, TokenData& out) {
    if (line.empty() || line[0] == '#') return false;

    auto field_view = extract_field(line, field_);
    if (field_view.empty()) return false;

    out.token_index = token_index_;
    out.format = format_;

    auto values = parse_json_array(field_view);
    if (values.empty()) return false;

    switch (format_) {
    case InputFormat::LOGITS:
        out.logits = std::move(values);
        break;
    case InputFormat::PROBS:
        out.probs = std::move(values);
        break;
    case InputFormat::LOGPROBS:
        out.logprobs = std::move(values);
        break;
    }

    return true;
}

bool StdinIngester::read_one(TokenCallback cb) {
    std::string line;
    if (!std::getline(std::cin, line)) return false;

    TokenData data;
    if (parse_jsonl_line(line, data)) {
        cb(data);
        ++token_index_;
    }
    return true;
}

void StdinIngester::read_all(TokenCallback cb) {
    while (read_one(cb)) {}
}

// ─── SocketIngester ──────────────────────────────────────────────────────────

SocketIngester::SocketIngester(std::filesystem::path socket_path)
    : path_(std::move(socket_path)) {}

bool SocketIngester::connect() {
    fd_ = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd_ < 0) return false;

    struct sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path_.c_str(), sizeof(addr.sun_path) - 1);

    if (::connect(fd_, reinterpret_cast<struct sockaddr*>(&addr), sizeof(addr)) < 0) {
        ::close(fd_);
        fd_ = -1;
        return false;
    }
    return true;
}

void SocketIngester::listen(TokenCallback cb) {
    if (!connect()) return;

    running_.store(true, std::memory_order_relaxed);
    StdinIngester parser("logits", InputFormat::LOGITS);
    char buf[65536];
    std::string leftover;

    while (running_.load(std::memory_order_relaxed)) {
        ssize_t n = ::read(fd_, buf, sizeof(buf));
        if (n <= 0) break;

        leftover.append(buf, static_cast<std::size_t>(n));

        std::size_t pos = 0;
        while (pos < leftover.size()) {
            auto nl = leftover.find('\n', pos);
            if (nl == std::string::npos) break;

            std::string_view line(leftover.data() + pos, nl - pos);
            TokenData data;
            if (parser.parse_jsonl_line(line, data)) {
                cb(data);
            }
            pos = nl + 1;
        }
        leftover.erase(0, pos);
    }

    close();
}

bool SocketIngester::read_one(TokenCallback cb, int timeout_ms) {
    if (fd_ < 0 && !connect()) return false;

    while (true) {
        if (!leftover_.empty()) {
            auto nl = leftover_.find('\n');
            if (nl != std::string::npos) {
                std::string_view line(leftover_.data(), nl);
                TokenData data;
                if (parser_.parse_jsonl_line(line, data)) {
                    cb(data);
                }
                leftover_.erase(0, nl + 1);
                return true;
            }
        }

        if (timeout_ms > 0) {
            struct timeval tv{};
            tv.tv_sec = timeout_ms / 1000;
            tv.tv_usec = (timeout_ms % 1000) * 1000;
            fd_set fds;
            FD_ZERO(&fds);
            FD_SET(fd_, &fds);
            if (::select(fd_ + 1, &fds, nullptr, nullptr, &tv) <= 0) return false;
        }

        char buf[65536];
        ssize_t n = ::read(fd_, buf, sizeof(buf));
        if (n <= 0) return false;

        leftover_.append(buf, static_cast<std::size_t>(n));
    }
}

void SocketIngester::close() {
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

void SocketIngester::stop() {
    running_.store(false, std::memory_order_relaxed);
    if (fd_ >= 0) {
        ::shutdown(fd_, SHUT_RDWR);
    }
}

// ─── ShmemIngester ───────────────────────────────────────────────────────────

ShmemIngester::ShmemIngester(std::string name, std::size_t max_tokens)
    : name_(std::move(name)), max_tokens_(max_tokens) {}

bool ShmemIngester::open() {
    // Try to open existing shared memory
    fd_ = ::shm_open(name_.c_str(), O_RDWR, 0);
    if (fd_ < 0) return false;

    mapped_size_ = sizeof(std::size_t) + max_tokens_ * sizeof(double);
    mapped_ = ::mmap(nullptr, mapped_size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (mapped_ == MAP_FAILED) {
        ::close(fd_);
        fd_ = -1;
        mapped_ = nullptr;
        return false;
    }

    return true;
}

std::span<const double> ShmemIngester::read_current() {
    if (!mapped_) return {};

    // Layout: [size_t count][double data[count]]
    auto* count = static_cast<std::size_t*>(mapped_);
    auto* data = reinterpret_cast<const double*>(
        static_cast<char*>(mapped_) + sizeof(std::size_t));

    std::size_t n = *count;
    if (n > max_tokens_) n = max_tokens_;

    return {data, n};
}

void ShmemIngester::poll(TokenCallback cb, int poll_interval_us) {
    stop_requested_.store(false, std::memory_order_relaxed);
    while (mapped_ && !stop_requested_.load(std::memory_order_relaxed)) {
        auto span = read_current();
        if (span.size() < last_seen_index_) {
            last_seen_index_ = 0;
        }
        if (span.size() > last_seen_index_) {
            TokenData data;
            data.token_index = last_seen_index_;
            data.logits.assign(span.begin() + last_seen_index_, span.end());
            data.format = InputFormat::LOGITS;
            cb(data);
            last_seen_index_ = span.size();
        }
        ::usleep(poll_interval_us);
    }
}

void ShmemIngester::close() {
    if (mapped_) {
        ::munmap(mapped_, mapped_size_);
        mapped_ = nullptr;
    }
    if (fd_ >= 0) {
        ::close(fd_);
        fd_ = -1;
    }
}

void ShmemIngester::stop() {
    stop_requested_.store(true, std::memory_order_relaxed);
}

}  // namespace shannon::ingest
