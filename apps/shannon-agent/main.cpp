// main.cpp — shannon-agent CLI entry point
//
// The thermodynamic physicochemical referee terminal agent.
// Sits on top of any LLM and detects entropy collapse indicating
// evaluation awareness or strategic deception.
//
// Usage:
//   cat token_stream.jsonl | shannon-agent
//   shannon-agent --socket /tmp/shannon.sock
//   shannon-agent --shmem /shannon_tokens
//
// Apache-2.0 © 2026 Le Bonhomme Pharma

#include "shannon/terminal_agent.hpp"
#include "shannon/config.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static void print_usage(const char* prog) {
    std::fprintf(stderr,
        "shannon-agent v%d.%d.%d — Thermodynamic LLM Safety Referee\n"
        "\n"
        "Usage: %s [options]\n"
        "\n"
        "Reads token distributions from stdin (JSONL), Unix socket, or shared memory.\n"
        "Detects Shannon entropy collapse indicating evaluation awareness or deception.\n"
        "\n"
        "Options:\n"
        "  --field <name>        JSONL field containing logits (default: logits)\n"
        "  --probs               Input is probability distribution\n"
        "  --logprobs            Input is log-probabilities\n"
        "  --window <n>          Sliding window size (default: %zu)\n"
        "  --threshold <bits>    Collapse threshold in bits (default: %.1f)\n"
        "  --socket <path>       Unix domain socket path\n"
        "  --shmem <name>        Shared memory name\n"
        "  --handrail <action>   First collapse action (default: alert): log|alert|throttle|kill|coredump|webhook\n"
        "  --sustained <action>  Sustained collapse action (default: kill): log|alert|throttle|kill|coredump|webhook\n"
        "  --count <n>           Sustained collapse count (default: %d)\n"
        "  --cooldown <secs>     Action cooldown seconds (default: %.1f)\n"
        "  --webhook <url>       Webhook URL for notifications\n"
        "  --pid <pid>           PID of monitored process (for signal handrails)\n"
        "  --log <path>          Log file path (default: stderr)\n"
        "  --quiet               Quiet mode (exit code only: 0=safe, 1=collapse)\n"
        "  --verbose             Verbose output (default)\n"
        "  -h, --help            Show this help\n"
        "\n"
        "Exit codes:\n"
        "  0  No collapse detected\n"
        "  1  Collapse detected\n"
        "  2  Initialization error\n"
        "\n"
        "Apache-2.0 © 2026 Le Bonhomme Pharma\n",
        shannon::kVersionMajor, shannon::kVersionMinor, shannon::kVersionPatch,
        prog,
        shannon::kDefaultWindowSize,
        shannon::kDefaultCollapseThreshold,
        shannon::kDefaultSustainedCount,
        shannon::kDefaultCooldownSeconds);
}

static shannon::HandrailAction parse_action(const char* s) {
    if (std::strcmp(s, "log") == 0)      return shannon::HandrailAction::LOG_ONLY;
    if (std::strcmp(s, "alert") == 0)     return shannon::HandrailAction::ALERT;
    if (std::strcmp(s, "throttle") == 0)  return shannon::HandrailAction::THROTTLE;
    if (std::strcmp(s, "kill") == 0)      return shannon::HandrailAction::KILL;
    if (std::strcmp(s, "coredump") == 0)  return shannon::HandrailAction::COREDUMP;
    if (std::strcmp(s, "webhook") == 0)   return shannon::HandrailAction::WEBHOOK;
    if (std::strcmp(s, "callback") == 0)  return shannon::HandrailAction::CALLBACK;
    std::fprintf(stderr, "Unknown action: %s (using LOG_ONLY)\n", s);
    return shannon::HandrailAction::LOG_ONLY;
}

int main(int argc, char* argv[]) {
    shannon::AgentConfig config;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];

        if (arg == "-h" || arg == "--help") {
            print_usage(argv[0]);
            return 0;
        } else if (arg == "--field" && i + 1 < argc) {
            config.jsonl_field = argv[++i];
        } else if (arg == "--probs") {
            config.input_format = shannon::InputFormat::PROBS;
        } else if (arg == "--logprobs") {
            config.input_format = shannon::InputFormat::LOGPROBS;
        } else if (arg == "--window" && i + 1 < argc) {
            config.window_size = static_cast<std::size_t>(std::stoul(argv[++i]));
        } else if (arg == "--threshold" && i + 1 < argc) {
            config.threshold_bits = std::stod(argv[++i]);
        } else if (arg == "--socket" && i + 1 < argc) {
            config.stream_mode = shannon::StreamMode::UNIX_SOCKET;
            config.socket_path = argv[++i];
        } else if (arg == "--shmem" && i + 1 < argc) {
            config.stream_mode = shannon::StreamMode::SHARED_MEMORY;
            config.shmem_name = argv[++i];
        } else if (arg == "--handrail" && i + 1 < argc) {
            config.handrail.on_first_collapse = parse_action(argv[++i]);
        } else if (arg == "--sustained" && i + 1 < argc) {
            config.handrail.on_sustained_collapse = parse_action(argv[++i]);
        } else if (arg == "--count" && i + 1 < argc) {
            config.handrail.sustained_threshold = std::stoi(argv[++i]);
        } else if (arg == "--cooldown" && i + 1 < argc) {
            config.handrail.cooldown_seconds = std::stod(argv[++i]);
        } else if (arg == "--webhook" && i + 1 < argc) {
            config.handrail.webhook_url = argv[++i];
        } else if (arg == "--pid" && i + 1 < argc) {
            config.handrail.monitored_pid = static_cast<pid_t>(std::stoi(argv[++i]));
        } else if (arg == "--log" && i + 1 < argc) {
            config.log_path = argv[++i];
        } else if (arg == "--quiet") {
            config.quiet = true;
            config.verbose = false;
        } else if (arg == "--verbose") {
            config.verbose = true;
            config.quiet = false;
        } else {
            std::fprintf(stderr, "Unknown option: %s\n", arg.c_str());
            print_usage(argv[0]);
            return 2;
        }
    }

    // Configure handrail logging
    config.handrail.log_path = config.log_path;

    try {
        shannon::TerminalAgent agent(std::move(config));
        return agent.run();
    } catch (const std::exception& e) {
        std::fprintf(stderr, "[shannon] Fatal: %s\n", e.what());
        return 2;
    }
}
