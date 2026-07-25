// collapse_detector.hpp — Sliding-window entropy event detector for Shannon 2.0
//
// Detects three classes of entropy anomaly:
//   COLLAPSE    — entropy drops below threshold (ordering / lock-in)
//   EXPANSION   — entropy rises above threshold (disordering / release)
//   OSCILLATION — rapid alternation between collapse and expansion
//
// Uses the unified dispatch for backend selection. Tracks entropy over a
// sliding window, computes z-score delta, and fires callbacks on events.
//
// ── Cross-backend contract (python/shannon/detector.py is the twin) ─────────
// This class and ShannonCollapseDetector._push in python/shannon/detector.py
// MUST produce byte-identical CollapseResults for the same entropy stream and
// the same parameters. Two invariants make that true; break either and the
// backends silently disagree about what a token was:
//
//   1. ORDER. Both keep the entropy window and the event history in
//      CHRONOLOGICAL order (oldest first) and both walk them oldest→newest.
//      The event history grows from EMPTY and is capped at oscillation_window;
//      it is never pre-seeded and never read in ring-buffer index order.
//   2. ARITHMETIC. Window mean/variance are one shared Welford recurrence with
//      the sample (n-1) denominator, evaluated in the same order with FP
//      contraction disabled, so both backends land on the same double.
//
// tests/python/test_detector.py::TestBackendParityFuzz enforces both by fuzz.
//
// ── Operator surface (env, read once per constructed detector) ──────────────
// Each backend parses these itself, under the ONE rule set documented here;
// TestOperatorSurfaceParity pins both to the same answers so the rules cannot
// drift apart.
//   SHANNON_OSCILLATION_MIN_ALTERNATIONS  (default 2, min 1)
//       Collapse↔expansion transitions required inside oscillation_window
//       before a token is labelled OSCILLATION. Raise it if oscillation fires
//       too often on your traffic; 1 makes any single flip oscillate.
//   SHANNON_DETECTOR_OBSERVE_ONLY  (default 0 = enforce)
//       1/true/yes/on: classify and return events exactly as normal but never
//       invoke the callback — i.e. measure, do not act. Use it to size the
//       event rate of a new threshold before wiring the handrail to it.
//   Both refuse to start on an unparseable value rather than silently falling
//   back to the default (a typo must not quietly change detection sensitivity).
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/types.hpp"
#include "shannon/config.hpp"
#include "shannon/unified_dispatch.hpp"

#include <cstddef>
#include <deque>
#include <functional>
#include <vector>

namespace shannon {

class CollapseDetector {
public:
    explicit CollapseDetector(
        std::size_t window_size = kDefaultWindowSize,
        double collapse_threshold = kDefaultCollapseThreshold,
        double expansion_threshold = kDefaultExpansionThreshold,
        std::size_t oscillation_window = kDefaultOscillationWindow);

    // Feed logits (unnormalized log-weights) — main entry point
    CollapseResult add_logits(const double* logits, std::size_t n);
    CollapseResult add_logits(std::span<const double> logits);

    // Feed probability distribution
    CollapseResult add_probs(const double* probs, std::size_t n);
    CollapseResult add_probs(std::span<const double> probs);

    // Feed log-probabilities
    CollapseResult add_logprobs(const double* logprobs, std::size_t n);
    CollapseResult add_logprobs(std::span<const double> logprobs);

    // Feed pre-computed entropy value directly
    CollapseResult push_entropy(double h);

    // Configuration
    void set_callback(CollapseCallback cb);
    void set_window_size(std::size_t size);
    void set_collapse_threshold(double threshold_bits);
    void set_expansion_threshold(double threshold_bits);
    void set_oscillation_window(std::size_t size);
    void set_max_trace_size(std::size_t max_size);
    void reset();

    // Operator knobs — env-driven, resolved once in the constructor. Read-only
    // accessors so a caller can log what it actually got. There is deliberately
    // no setter: the value must be identical for every detector in the process
    // and for the Python twin, and one env read is the only way to guarantee
    // that. See the env documentation at the top of this header.
    std::size_t min_alternations() const noexcept;
    bool observe_only() const noexcept;

    // Legacy compat
    void set_threshold(double threshold_bits);

    // Accessors
    std::size_t token_count() const noexcept;
    const std::deque<double>& entropy_trace() const noexcept;

private:
    static constexpr std::size_t MAX_TRACE = 10000;  // hard cap: prevents unbounded growth

    std::size_t window_size_;
    double collapse_threshold_;
    double expansion_threshold_;
    std::size_t oscillation_window_;
    std::vector<double> window_;   // ring buffer; window_pos_ = next write slot
    std::size_t window_pos_ = 0;
    bool window_full_ = false;
    std::size_t token_count_ = 0;
    std::size_t max_trace_size_ = MAX_TRACE;
    std::deque<double> trace_;
    // Chronological, oldest first, capped at oscillation_window_. A deque —
    // not a ring buffer indexed by token_count_ — because detect_oscillation()
    // counts ADJACENT transitions: reading a ring in array order hands it a
    // ROTATION of the real history, inventing one adjacency between the newest
    // and the oldest event and dropping one real one. See the .cpp.
    std::deque<EntropyEvent> event_history_;
    std::size_t min_alternations_;
    bool observe_only_;
    CollapseCallback callback_;

    EntropyEvent classify_event(double delta, bool window_ready) const;
    bool detect_oscillation() const;
};

}  // namespace shannon
