// collapse_detector.cpp — Sliding-window entropy event detector
//
// Detects collapse, expansion, and oscillation in LLM token entropy.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/collapse_detector.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <stdexcept>
#include <string>

namespace shannon {

namespace {

// ── Operator env parsing ────────────────────────────────────────────────────
// Deliberately strict: an unparseable SHANNON_* value throws instead of
// falling back to the default. A silently-ignored typo in
// SHANNON_OSCILLATION_MIN_ALTERNATIONS would leave an operator believing they
// had retuned the detector while it ran at stock sensitivity — the exact class
// of silent no-op this detector has been bitten by before. Failing at
// construction is loud, immediate and fixable.

bool env_observe_only(const char* name, bool fallback) {
    const char* raw = std::getenv(name);
    if (raw == nullptr) return fallback;
    std::string v(raw);
    // Trim + lowercase so "1", " true", "ON" all behave the same as in Python.
    const auto first = v.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return fallback;   // empty/blank == unset
    const auto last = v.find_last_not_of(" \t\r\n");
    v = v.substr(first, last - first + 1);
    for (auto& c : v) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if (v == "1" || v == "true" || v == "yes" || v == "on")   return true;
    if (v == "0" || v == "false" || v == "no" || v == "off")  return false;
    throw std::invalid_argument(
        std::string(name) + ": expected one of 1/0/true/false/yes/no/on/off, got '" +
        raw + "'; refusing to start with an ambiguous enforcement mode");
}

std::size_t env_min_alternations(const char* name, std::size_t fallback) {
    const char* raw = std::getenv(name);
    if (raw == nullptr) return fallback;
    std::string v(raw);
    const auto first = v.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) return fallback;
    const auto last = v.find_last_not_of(" \t\r\n");
    v = v.substr(first, last - first + 1);
    try {
        std::size_t consumed = 0;
        const long long parsed = std::stoll(v, &consumed);
        if (consumed != v.size() || parsed < 1) throw std::invalid_argument("range");
        return static_cast<std::size_t>(parsed);
    } catch (const std::exception&) {
        throw std::invalid_argument(
            std::string(name) + ": expected an integer >= 1, got '" + raw +
            "'; refusing to start with an unknown oscillation sensitivity");
    }
}

// ── Shared window statistics ────────────────────────────────────────────────

struct WindowStats {
    double mean;
    double stddev;
};

// Welford: O(n), stable. Replaces E[X²]-E[X]² which cancels catastrophically
// near H≈2 bits — and which python/shannon/detector.py used to keep using,
// with a POPULATION (n) denominator against this function's SAMPLE (n-1) one,
// so window_std and z_score disagreed between the backends on every single
// token. detector.py::_welford_window_stats is now a line-for-line twin of
// this loop. Three properties are load-bearing for that; none may be
// "optimised" on one side only:
//   * SAMPLE variance, M2/(count-1), zero for count < 2.
//   * CHRONOLOGICAL iteration (oldest first), not raw ring order. Same set,
//     different summation order, ~1 ULP apart — enough to flip .collapsed when
//     delta lands exactly on the threshold.
//   * FP contraction OFF, so `M2 += delta * delta2` cannot become an FMA. An
//     FMA skips a rounding and is likewise ~1 ULP off Python, which has no
//     fused multiply-add. The 6/400 callback-count divergences the audit found
//     were exactly this class of 1-ULP disagreement.
// tests/python/test_detector.py::TestBackendParityFuzz compares mean/std with
// == (not approx), so any of these regressing fails a test rather than a
// deployment.
#if defined(__GNUC__) && !defined(__clang__)
#  pragma GCC push_options
#  pragma GCC optimize("-ffp-contract=off")
#endif
WindowStats welford_window_stats(const std::vector<double>& window,
                                 std::size_t oldest,
                                 std::size_t count) {
#if defined(__clang__)
#  pragma clang fp contract(off)
#endif
    const std::size_t n = window.size();
    double mean = 0.0;
    double M2 = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        const double x = window[(oldest + i) % n];
        const double delta = x - mean;
        mean += delta / static_cast<double>(i + 1);
        const double delta2 = x - mean;
        const double prod = delta * delta2;   // separate statement: no contraction
        M2 += prod;
    }
    const double variance = (count > 1) ? M2 / static_cast<double>(count - 1) : 0.0;
    return WindowStats{mean, std::sqrt(std::max(0.0, variance))};
}
#if defined(__GNUC__) && !defined(__clang__)
#  pragma GCC pop_options
#endif

}  // namespace

CollapseDetector::CollapseDetector(
    std::size_t window_size,
    double collapse_threshold,
    double expansion_threshold,
    std::size_t oscillation_window)
    : window_size_(window_size > 0 ? window_size : kDefaultWindowSize)
    , collapse_threshold_(collapse_threshold)
    , expansion_threshold_(expansion_threshold > 0 ? expansion_threshold : -collapse_threshold)
    , oscillation_window_(oscillation_window > 0 ? oscillation_window : kDefaultOscillationWindow)
    , window_(window_size_, 0.0)
    // Starts EMPTY and grows, exactly like Python's deque(maxlen=...). The old
    // pre-seed of oscillation_window_ NONEs was invisible to the alternation
    // count but made the two backends' histories structurally different, which
    // is how the rotation bug below stayed hidden for so long.
    , event_history_()
    , min_alternations_(env_min_alternations("SHANNON_OSCILLATION_MIN_ALTERNATIONS", 2))
    , observe_only_(env_observe_only("SHANNON_DETECTOR_OBSERVE_ONLY", false)) {}

void CollapseDetector::reset() {
    trace_.clear();
    std::fill(window_.begin(), window_.end(), 0.0);
    event_history_.clear();
    window_pos_ = 0;
    window_full_ = false;
    token_count_ = 0;
}

CollapseResult CollapseDetector::add_logits(std::span<const double> logits) {
    auto& dispatch = dispatch::UnifiedDispatch::instance();

    double h = 0.0;
    auto result = dispatch.compute_configurational_entropy(logits, h);

    CollapseResult cr = push_entropy(h);
    cr.used_backend = result.used_backend;
    return cr;
}

CollapseResult CollapseDetector::add_logits(const double* logits, std::size_t n) {
    if (logits == nullptr || n == 0) {
        return add_logits(std::span<const double>{});
    }
    return add_logits(std::span<const double>{logits, n});
}

CollapseResult CollapseDetector::add_probs(std::span<const double> probs) {
    auto& dispatch = dispatch::UnifiedDispatch::instance();

    double h = 0.0;
    auto result = dispatch.compute_entropy_from_probs(probs, h);

    CollapseResult cr = push_entropy(h);
    cr.used_backend = result.used_backend;
    return cr;
}

CollapseResult CollapseDetector::add_probs(const double* probs, std::size_t n) {
    if (probs == nullptr || n == 0) {
        return add_probs(std::span<const double>{});
    }
    return add_probs(std::span<const double>{probs, n});
}

CollapseResult CollapseDetector::add_logprobs(std::span<const double> logprobs) {
    auto& dispatch = dispatch::UnifiedDispatch::instance();

    double h = 0.0;
    auto result = dispatch.compute_entropy_from_logprobs(logprobs, h);

    CollapseResult cr = push_entropy(h);
    cr.used_backend = result.used_backend;
    return cr;
}

CollapseResult CollapseDetector::add_logprobs(const double* logprobs, std::size_t n) {
    if (logprobs == nullptr || n == 0) {
        return add_logprobs(std::span<const double>{});
    }
    return add_logprobs(std::span<const double>{logprobs, n});
}

EntropyEvent CollapseDetector::classify_event(double delta, bool window_ready) const {
    if (!window_ready) return EntropyEvent::NONE;
    if (delta < collapse_threshold_) return EntropyEvent::COLLAPSE;
    if (delta > expansion_threshold_) return EntropyEvent::EXPANSION;
    return EntropyEvent::NONE;
}

bool CollapseDetector::detect_oscillation() const {
    // event_history_ is chronological (oldest first), so index i-1 really did
    // precede index i. It used to be a ring buffer written at
    // token_count_ % oscillation_window_ and READ IN ARRAY ORDER, which after
    // the first wrap hands this loop a rotation of the true history: the pair
    // (newest, oldest) becomes adjacent and one genuine adjacent pair is lost.
    // For a perfectly periodic stream a rotation is indistinguishable from the
    // original — which is why the old parity test passed while 289/400 random
    // streams disagreed with the Python reference.
    std::size_t alternations = 0;
    for (std::size_t i = 1; i < event_history_.size(); ++i) {
        EntropyEvent prev = event_history_[i - 1];
        EntropyEvent curr = event_history_[i];
        if ((prev == EntropyEvent::COLLAPSE && curr == EntropyEvent::EXPANSION) ||
            (prev == EntropyEvent::EXPANSION && curr == EntropyEvent::COLLAPSE)) {
            ++alternations;
        }
    }
    return alternations >= min_alternations_;
}

CollapseResult CollapseDetector::push_entropy(double h) {
    // Fail closed on a non-finite entropy. A NaN poisons the window for
    // window_size tokens and makes every threshold comparison false, i.e. it
    // silently switches the detector OFF; an infinity manufactures a collapse
    // or an expansion on the next token. Neither may be accepted quietly.
    if (!std::isfinite(h)) {
        throw std::invalid_argument(
            "push_entropy: entropy must be finite, got " + std::to_string(h) +
            "; refusing to admit a non-finite value into the sliding window");
    }

    trace_.push_back(h);
    if (trace_.size() > max_trace_size_) {
        trace_.pop_front();   // O(1) with deque; max_trace_size_ defaults to MAX_TRACE (10000)
    }

    window_[window_pos_] = h;
    window_pos_ = (window_pos_ + 1) % window_size_;
    if (!window_full_ && window_pos_ == 0) {
        window_full_ = true;
    }

    const std::size_t count = window_full_ ? window_size_ : window_pos_;

    // window_pos_ now points at the next slot to overwrite, which is the OLDEST
    // sample once the ring has wrapped. Before it wraps the samples sit at
    // 0..count-1 in order.
    const std::size_t oldest = window_full_ ? window_pos_ : 0;
    const WindowStats stats = welford_window_stats(window_, oldest, count);
    const double mean   = stats.mean;
    const double stddev = stats.stddev;

    const double delta = h - mean;
    const double z = (stddev > 1e-12) ? delta / stddev : 0.0;
    const bool window_ready = (count >= window_size_);

    EntropyEvent event = classify_event(delta, window_ready);

    // Latch the threshold verdict BEFORE `event` can be rewritten to
    // OSCILLATION below. CollapseResult::collapsed is documented as
    // "true if delta < collapse_threshold" (types.hpp) and the Python
    // fallback keeps it independent of the oscillation relabelling, so
    // reading it back off the rewritten `event` silently reported
    // collapsed=false for every collapse inside an oscillating stretch —
    // suppressing the on_collapse callback for exactly the alternating
    // pattern this detector exists to flag. OSCILLATION stays a label on
    // `.event`; consumers wanting the mutually-exclusive classification
    // read `.event`, not `.collapsed`.
    const bool collapsed = (event == EntropyEvent::COLLAPSE);
    const bool expanded  = (event == EntropyEvent::EXPANSION);

    event_history_.push_back(event);
    while (event_history_.size() > oscillation_window_) {
        event_history_.pop_front();   // maxlen semantics, chronological order preserved
    }
    bool oscillating = false;
    if (window_ready && event != EntropyEvent::NONE) {
        oscillating = detect_oscillation();
    }
    if (oscillating) {
        event = EntropyEvent::OSCILLATION;
    }

    CollapseResult result{
        .entropy     = h,
        .window_mean = mean,
        .window_std  = stddev,
        .delta       = delta,
        .z_score     = z,
        .collapsed   = collapsed,
        .expanded    = expanded,
        .oscillating = oscillating,
        .event       = event,
        .token_index = token_count_,
        .used_backend = Backend::SCALAR,
    };

    ++token_count_;

    // observe_only_ suppresses the ACTION, never the classification: the
    // result is fully populated and returned either way, so a deployment can
    // count what a new threshold would have done before letting it reach the
    // handrail. Enforcement is the default; observation is opt-in.
    if ((result.collapsed || result.expanded || result.oscillating) && callback_ && !observe_only_) {
        callback_(result);
    }

    return result;
}

void CollapseDetector::set_callback(CollapseCallback cb) {
    callback_ = std::move(cb);
}

void CollapseDetector::set_window_size(std::size_t size) {
    window_size_ = (size > 0) ? size : kDefaultWindowSize;
    window_.assign(window_size_, 0.0);
    window_pos_ = 0;
    window_full_ = false;
}

void CollapseDetector::set_collapse_threshold(double threshold_bits) {
    collapse_threshold_ = threshold_bits;
}

void CollapseDetector::set_expansion_threshold(double threshold_bits) {
    expansion_threshold_ = threshold_bits;
}

void CollapseDetector::set_oscillation_window(std::size_t size) {
    oscillation_window_ = (size > 0) ? size : kDefaultOscillationWindow;
    // Trim the OLDEST entries only. assign()-ing a fresh block of NONEs here
    // wiped every event seen so far, so shrinking the window mid-stream also
    // blinded oscillation detection for the next oscillation_window tokens.
    while (event_history_.size() > oscillation_window_) {
        event_history_.pop_front();
    }
}

std::size_t CollapseDetector::min_alternations() const noexcept {
    return min_alternations_;
}

bool CollapseDetector::observe_only() const noexcept {
    return observe_only_;
}

void CollapseDetector::set_threshold(double threshold_bits) {
    collapse_threshold_ = threshold_bits;
}

void CollapseDetector::set_max_trace_size(std::size_t max_size) {
    max_trace_size_ = (max_size > 0) ? max_size : MAX_TRACE;
    while (trace_.size() > max_trace_size_) {
        trace_.pop_front();
    }
}

std::size_t CollapseDetector::token_count() const noexcept {
    return token_count_;
}

std::size_t CollapseDetector::oscillation_window() const noexcept {
    return oscillation_window_;
}

const std::deque<double>& CollapseDetector::entropy_trace() const noexcept {
    return trace_;
}

}  // namespace shannon
