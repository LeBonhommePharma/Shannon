# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""Tests for the Shannon entropy collapse detector (Python)."""

import functools
import math
import random

import numpy as np
from shannon import (
    CollapseEvent,
    CollapseResult,
    ShannonCollapseDetector,
    shannon_configurational_entropy,
    shannon_entropy_from_logprobs,
    shannon_entropy_from_probs,
)
from shannon._numba_fallback import get_backend

# ── Core entropy functions ───────────────────────────────────────────────────


class TestConfigurationalEntropy:
    def test_empty(self):
        assert shannon_configurational_entropy([]) == 0.0

    def test_single(self):
        assert shannon_configurational_entropy([5.0]) == 0.0

    def test_uniform(self):
        # N equal → log2(N)
        N = 1024
        h = shannon_configurational_entropy(np.zeros(N))
        assert abs(h - math.log2(N)) < 1e-10

    def test_delta(self):
        h = shannon_configurational_entropy([100.0, -100.0, -100.0])
        assert h < 0.01

    def test_two_equal(self):
        h = shannon_configurational_entropy([0.0, 0.0])
        assert abs(h - 1.0) < 1e-10

    def test_numerical_stability_large(self):
        h = shannon_configurational_entropy([1000.0, 1000.0, 1000.0, 1000.0])
        assert abs(h - 2.0) < 1e-10

    def test_numerical_stability_negative(self):
        h = shannon_configurational_entropy([-1000.0, -1000.0])
        assert abs(h - 1.0) < 1e-10

    def test_large_vocabulary(self):
        rng = np.random.default_rng(42)
        logits = rng.normal(0, 3, size=50000)
        h = shannon_configurational_entropy(logits)
        assert 0 < h <= math.log2(50000)


class TestEntropyFromProbs:
    def test_uniform(self):
        h = shannon_entropy_from_probs([0.25, 0.25, 0.25, 0.25])
        assert abs(h - 2.0) < 1e-10

    def test_delta(self):
        h = shannon_entropy_from_probs([1.0, 0.0, 0.0])
        assert abs(h) < 1e-10

    def test_binary(self):
        h = shannon_entropy_from_probs([0.5, 0.5])
        assert abs(h - 1.0) < 1e-10


class TestEntropyFromLogprobs:
    def test_uniform(self):
        lp = math.log(0.25)
        h = shannon_entropy_from_logprobs([lp, lp, lp, lp])
        assert abs(h - 2.0) < 1e-10


# ── Collapse Detector ────────────────────────────────────────────────────────


class TestShannonCollapseDetector:
    def test_basic_flow(self):
        det = ShannonCollapseDetector(window_size=4, threshold=-2.0)
        uniform = np.zeros(8)  # log2(8) = 3 bits
        for _ in range(4):
            r = det.add_logits(uniform)
            assert not r.collapsed

    def test_collapse_detection(self):
        det = ShannonCollapseDetector(window_size=4, threshold=-2.0)

        # Fill window with high-entropy
        for _ in range(4):
            det.add_logits(np.zeros(1024))

        # Inject low-entropy → collapse
        spike = np.full(1024, -100.0)
        spike[0] = 100.0
        result = det.add_logits(spike)
        assert result.delta < 0

    def test_callback(self):
        events = []
        det = ShannonCollapseDetector(
            window_size=4,
            threshold=-1.0,
            callback=lambda r: events.append(r),
        )

        for _ in range(4):
            det.add_logits(np.zeros(8))

        spike = np.full(8, -100.0)
        spike[0] = 100.0
        det.add_logits(spike)

        assert len(events) >= 1

    def test_trace(self):
        det = ShannonCollapseDetector()
        rng = np.random.default_rng(99)
        for _ in range(10):
            det.add_logits(rng.standard_normal(100))
        assert len(det.trace) == 10

    def test_reset(self):
        det = ShannonCollapseDetector()
        det.add_logits(np.zeros(10))
        assert len(det.trace) == 1
        det.reset()
        assert len(det.trace) == 0

    def test_probs_interface(self):
        det = ShannonCollapseDetector()
        probs = np.array([0.25, 0.25, 0.25, 0.25])
        result = det.add_probs(probs)
        assert abs(result.entropy - 2.0) < 1e-10

    def test_logprobs_interface(self):
        det = ShannonCollapseDetector()
        logprobs = np.log(np.array([0.5, 0.5]))
        result = det.add_logprobs(logprobs)
        assert abs(result.entropy - 1.0) < 1e-10


# ── Synthetic collapse patterns ──────────────────────────────────────────────


class TestSyntheticPatterns:
    """Test with realistic synthetic patterns mimicking LLM behaviour."""

    def test_gradual_then_sudden_collapse(self):
        """Steady entropy followed by a sharp drop → collapse."""
        det = ShannonCollapseDetector(window_size=8, threshold=-3.0)

        # Steady high-entropy phase (fill window)
        for _ in range(16):
            det.add_logits(np.zeros(1000))  # log2(1000) ≈ 10 bits

        # Sudden drop: only 2 active logits → log2(2) = 1 bit
        # delta ≈ 1 - 10 = -9, well below threshold
        logits = np.full(1000, -100.0)
        logits[:2] = 0.0
        result = det.add_logits(logits)
        assert result.collapsed

    def test_sudden_spike(self):
        """Single sudden entropy drop (evaluation awareness signal)."""
        det = ShannonCollapseDetector(window_size=8, threshold=-3.0)

        # Steady high entropy
        for _ in range(16):
            det.add_logits(np.zeros(1000))

        # Sudden collapse
        spike = np.full(1000, -100.0)
        spike[0] = 100.0
        result = det.add_logits(spike)
        assert result.collapsed
        assert result.z_score < -2.0

    def test_no_false_positive_stable(self):
        """Stable entropy should not trigger false collapses."""
        det = ShannonCollapseDetector(window_size=8, threshold=-3.2)

        rng = np.random.default_rng(42)
        collapses = 0
        for _ in range(1000):
            logits = rng.normal(0, 1, size=100)
            result = det.add_logits(logits)
            if result.collapsed:
                collapses += 1

        # FP rate should be very low
        assert collapses / 1000 < 0.01


class TestBackend:
    def test_backend_available(self):
        backend = get_backend()
        assert backend in ("cpp", "numba", "numpy")


# ── Input policy: refuse garbage instead of silently returning H=0.0 ─────────
#
# For a safety library, H=0.0 is the *alarm* condition ("total collapse").
# Empty or non-finite input must raise ValueError before any entropy is
# computed, on BOTH the C++ fast path and the pure-Python fallback, so garbage
# can neither manufacture nor mask the collapse signal.

import pytest


def _both_backends():
    """Yield (label, detector-factory) for the cpp fast path and forced Python."""
    factories = [("cpp", lambda: ShannonCollapseDetector(window_size=4))]

    def _py():
        det = ShannonCollapseDetector(window_size=4)
        det._cpp_detector = None  # force the pure-Python entropy path
        det._backend = "python"
        return det

    factories.append(("python", _py))
    return factories


class TestInputPolicy:
    @pytest.mark.parametrize("label,make", _both_backends())
    @pytest.mark.parametrize("method", ["add_logits", "add_probs", "add_logprobs"])
    def test_empty_raises(self, label, make, method):
        det = make()
        with pytest.raises(ValueError, match="empty"):
            getattr(det, method)(np.array([], dtype=np.float64))

    @pytest.mark.parametrize("label,make", _both_backends())
    @pytest.mark.parametrize("method", ["add_logits", "add_probs", "add_logprobs"])
    def test_nan_raises(self, label, make, method):
        det = make()
        with pytest.raises(ValueError, match="NaN at index"):
            getattr(det, method)(np.array([0.1, 0.2, np.nan, 0.4]))

    @pytest.mark.parametrize("label,make", _both_backends())
    @pytest.mark.parametrize("method", ["add_logits", "add_probs", "add_logprobs"])
    def test_posinf_raises(self, label, make, method):
        det = make()
        with pytest.raises(ValueError, match=r"\+Inf at index"):
            getattr(det, method)(np.array([0.1, np.inf, 0.3]))

    @pytest.mark.parametrize("label,make", _both_backends())
    @pytest.mark.parametrize("method", ["add_logits", "add_probs", "add_logprobs"])
    def test_neginf_raises(self, label, make, method):
        det = make()
        with pytest.raises(ValueError, match=r"\-Inf at index"):
            getattr(det, method)(np.array([0.1, -np.inf, 0.3]))

    def test_error_message_reports_index(self):
        det = ShannonCollapseDetector(window_size=4)
        with pytest.raises(ValueError, match="index 2"):
            det.add_logits(np.array([0.1, 0.2, np.nan, 0.4]))

    @pytest.mark.parametrize("label,make", _both_backends())
    def test_single_finite_element_ok(self, label, make):
        # n == 1 must still work — the one-hot fallback in the streaming
        # integrations relies on add_probs(np.array([1.0])).
        det = make()
        r = det.add_probs(np.array([1.0], dtype=np.float64))
        assert r.entropy == 0.0  # single-element distribution has zero entropy
        r2 = det.add_logits(np.array([3.0], dtype=np.float64))
        assert r2 is not None

    def test_cpp_core_empty_raises(self):
        # Direct _core users are protected against the empty case too.
        core = pytest.importorskip("shannon._core")
        det = core.CollapseDetector(4, -3.2, 3.2, 16)
        for method in ("add_logits", "add_probs", "add_logprobs"):
            with pytest.raises(ValueError):
                getattr(det, method)(np.array([], dtype=np.float64))


# ── Callback contracts ───────────────────────────────────────────────────────


class TestCallbackContracts:
    """`callback` is handed a CollapseResult, `on_collapse` a CollapseEvent.

    The two used to be merged (`self._callback = callback or on_collapse`), so a
    caller passing only the legacy on_collapse had their CollapseEvent handler
    invoked with a CollapseResult and raised AttributeError on delta_h. The C++
    fast path compounded it by wiring only _callback, so on_collapse never fired
    at all whenever the compiled core was present -- i.e. by default.
    """

    @staticmethod
    def _drive_to_collapse(detector):
        rng = np.random.default_rng(0)
        for _ in range(10):
            detector.add_logits(rng.normal(0, 0.01, 1024))
        spike = np.full(1024, -100.0)
        spike[0] = 100.0
        detector.add_logits(spike)

    def test_on_collapse_receives_a_collapse_event(self):
        seen: list[object] = []
        det = ShannonCollapseDetector(window_size=4, threshold=-3.0, on_collapse=seen.append)
        self._drive_to_collapse(det)

        assert seen, "legacy on_collapse callback never fired"
        evt = seen[0]
        assert isinstance(evt, CollapseEvent)
        # Precisely the attributes CollapseResult does not carry; touching any
        # of them is what used to raise AttributeError.
        assert evt.delta_h < 0
        assert evt.collapse_score > 0
        assert len(evt.window) > 0

    def test_callback_receives_a_collapse_result(self):
        seen: list[object] = []
        det = ShannonCollapseDetector(window_size=4, threshold=-3.0, callback=seen.append)
        self._drive_to_collapse(det)

        assert seen, "callback never fired"
        assert all(isinstance(r, CollapseResult) for r in seen)

    def test_both_callbacks_fire_with_their_own_type(self):
        results: list[object] = []
        events: list[object] = []
        det = ShannonCollapseDetector(
            window_size=4,
            threshold=-3.0,
            callback=results.append,
            on_collapse=events.append,
        )
        self._drive_to_collapse(det)

        assert len(events) == 1, f"expected exactly one collapse event, got {len(events)}"
        assert all(isinstance(e, CollapseEvent) for e in events)
        assert results, "modern callback never fired"
        assert all(isinstance(r, CollapseResult) for r in results)


# ── Backend parity ───────────────────────────────────────────────────────────
#
# The C++ fast path and the pure-Python fallback must be indistinguishable from
# the outside: same callbacks, same counts, same detector state while a user
# callback is running. Every test below runs the SAME stream through both.


def _pin_backend(det: ShannonCollapseDetector, backend: str) -> ShannonCollapseDetector:
    """Pin an already-constructed detector to 'cpp' or 'python'."""
    if backend == "python":
        det._cpp_detector = None  # force the pure-Python entropy path
        det._backend = "python"
        return det
    if det._cpp_detector is None:  # pragma: no cover - depends on build
        pytest.skip("compiled shannon._core not available")
    assert get_backend() == "cpp", "cpp parametrisation requires the compiled core"
    return det


def _uniform_logits(bits: int) -> np.ndarray:
    """Uniform logits over 2**bits states → entropy is exactly `bits` bits."""
    return np.zeros(2**bits, dtype=np.float64)


class TestCallbackSeesCurrentToken:
    """Detector state inside a callback must describe the token that fired it.

    On the C++ fast path the callback runs from *inside*
    self._cpp_detector.add_logits(...), so assigning self._last_result on the
    line after that call left every convenience property one token stale:
    is_collapsed read False in the middle of a collapse. The pure-Python _push
    assigns _last_result before calling _emit, so the two backends disagreed --
    the exact divergence _emit exists to remove.
    """

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_properties_are_current_inside_callback(self, backend):
        snapshots: list[tuple] = []
        det = ShannonCollapseDetector(
            window_size=4,
            threshold=-3.0,
            callback=lambda r: snapshots.append(
                (det.is_collapsed, det.current_entropy, det.collapse_score, det.delta_h, r)
            ),
        )
        _pin_backend(det, backend)

        for _ in range(8):
            det.add_logits(_uniform_logits(10))  # steady 10 bits
        det.add_logits(_uniform_logits(0))  # → 0 bits: collapse

        assert snapshots, "callback never fired"
        is_collapsed, entropy, score, delta_h, result = snapshots[-1]
        assert result.event == "collapse"
        assert is_collapsed is True, "is_collapsed read False during a collapse callback"
        assert entropy == pytest.approx(result.entropy), "current_entropy was one token stale"
        assert score == pytest.approx(abs(result.delta / -3.0)), "collapse_score was stale"
        assert delta_h != 0.0

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_on_collapse_event_window_ends_on_the_collapsing_token(self, backend):
        events: list[CollapseEvent] = []
        det = ShannonCollapseDetector(window_size=4, threshold=-3.0, on_collapse=events.append)
        _pin_backend(det, backend)

        for _ in range(8):
            det.add_logits(_uniform_logits(10))
        det.add_logits(_uniform_logits(0))

        assert len(events) == 1
        assert events[0].window == pytest.approx([10.0, 10.0, 10.0, 0.0])
        assert events[0].entropy == pytest.approx(0.0)


class TestOscillatingCollapseParity:
    """A collapse that is also part of an oscillation is still a collapse.

    collapse_detector.cpp derived `.collapsed` from `event` *after* `event` had
    been rewritten to OSCILLATION, so on the C++ backend `collapsed` (and
    `expanded`) went false for every event inside an oscillating stretch. Since
    _emit fires the legacy on_collapse only when result.collapsed is true, the
    callback went silent for exactly the alternating collapse/expansion pattern
    this library exists to flag.

    NOTE ON THE STREAM. `[8] + [2, 10] * 8` is perfectly periodic, so a
    ROTATION of the event history is indistinguishable from the history itself.
    That is precisely why this class's old cross-backend assertions passed while
    289/400 randomised streams disagreed: the C++ core read its event history in
    ring-buffer index order (a rotation) and this stream could not tell the
    difference. The cross-backend claims have moved to
    TestBackendParityFuzz/TestOscillationHistoryIsChronological, which use
    non-periodic streams. What is left here is the single-backend invariant this
    class was actually written for.
    """

    STREAM = [8] + [2, 10] * 8  # bits: one baseline token, then alternating

    def _run(self, backend):
        events: list[CollapseEvent] = []
        results: list[CollapseResult] = []
        det = ShannonCollapseDetector(
            window_size=6,
            threshold=-1.0,
            expansion_threshold=1.0,
            oscillation_window=5,
            callback=results.append,
            on_collapse=events.append,
        )
        _pin_backend(det, backend)
        flags = []
        for bits in self.STREAM:
            r = det.add_logits(_uniform_logits(bits))
            flags.append((r.collapsed, r.expanded, r.oscillating, r.event))
        return events, results, flags

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_oscillation_does_not_clear_the_threshold_verdict(self, backend):
        _, results, _ = self._run(backend)
        oscillating = [r for r in results if r.event == "oscillation"]
        assert oscillating, "stream did not oscillate"
        # Every oscillating token is still either a collapse or an expansion:
        # OSCILLATION labels the pattern, it does not erase the verdict.
        assert all(r.collapsed or r.expanded for r in oscillating)
        assert any(r.collapsed for r in oscillating)

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_collapses_inside_the_oscillation_still_fire_on_collapse(self, backend):
        events, _, _ = self._run(backend)
        assert len(events) > 1, "collapses inside an oscillating stretch never fired"


# ── Backend parity: property-based fuzz ──────────────────────────────────────
#
# The C++ core and the pure-Python fallback are two implementations of one
# state machine, and this project has twice shipped a "verified" parity claim
# whose test was weaker than the claim. The tests below are the standing
# defence: randomised streams AND randomised parameters, a fixed seed, and
# EXACT comparison of every observable -- flags, event labels, callback
# ordering, and the window statistics themselves (== , not approx).
#
# Two root causes they were written against, both closed:
#
#   1. EVENT HISTORY ROTATION. collapse_detector.cpp stored events in a ring
#      buffer written at `token_count_ % oscillation_window_` and then counted
#      collapse<->expansion transitions by walking that array in INDEX order.
#      After the first wrap that is a rotation of the true history: it invents
#      an adjacency between the newest and the oldest event and drops one real
#      adjacency. Python's deque(maxlen=...) was chronological and therefore
#      right -- and types.hpp documents OSCILLATION as "rapid alternation",
#      which only means anything in time order -- so the C++ was fixed to match
#      the Python. Divergence: .oscillating in 289/400 fuzzed streams.
#
#   2. TWO DIFFERENT VARIANCES AND TWO DIFFERENT MEANS. C++ used Welford with
#      the sample (n-1) denominator; Python used running sums with the
#      population (n) denominator. window_std/z_score therefore disagreed on
#      EVERY token, and the mean drifted ~1e-15 apart, which flipped .collapsed
#      / .expanded whenever delta landed exactly on the threshold (6/400
#      callback-count divergences). Fixed by making the two computations
#      numerically identical -- one shared Welford recurrence, same order, FP
#      contraction disabled -- NOT by loosening the flag comparison. There is
#      no tolerance band on any flag anywhere in this file; mean and std are
#      compared with ==.

_PARITY_SEED = 20260724
_PARITY_CASES = 400

# Entropy values on a coarse grid. Integers and halves make exact window means,
# which is what puts delta exactly ON the threshold and exposes 1-ULP
# disagreements; the continuous streams cover everything else.
_GRID_BITS = (0.0, 0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 10.0, 12.0)


def _parity_cases():
    """Deterministic (params, stream) pairs. Fixed seed => reproducible failures."""
    rng = random.Random(_PARITY_SEED)
    cases = []
    for i in range(_PARITY_CASES):
        params = dict(
            window_size=rng.randint(2, 8),
            threshold=rng.choice([-0.5, -1.0, -2.0, -3.2]),
            expansion_threshold=rng.choice([0.5, 1.0, 2.0, 3.2]),
            oscillation_window=rng.randint(3, 7),
        )
        n = rng.randint(20, 60)
        if i % 2 == 0:
            stream = [rng.choice(_GRID_BITS) for _ in range(n)]
        else:
            stream = [rng.uniform(0.0, 12.0) for _ in range(n)]
        cases.append((params, tuple(stream)))
    return cases


def _run_parity(backend, params, stream):
    """Drive one stream through one backend and record every observable.

    One pass: the callback log, the per-token flags and the window statistics
    all describe the same run, so a divergence in any of them is attributable
    to the same token.
    """
    calls: list[tuple] = []
    det = ShannonCollapseDetector(
        callback=lambda r: calls.append(("callback", r.token_index, r.event)),
        on_collapse=lambda e: calls.append(("on_collapse", e.token_index, e.window[-1])),
        **params,
    )
    _pin_backend(det, backend)
    per_token = []
    stats = []
    for h in stream:
        r = det.push_entropy(h)
        per_token.append((r.collapsed, r.expanded, r.oscillating, r.event, r.token_index))
        stats.append((r.window_mean, r.window_std, r.delta, r.z_score))
    return per_token, tuple(calls), stats


@functools.lru_cache(maxsize=1)
def _parity_records():
    """(params, stream, cpp_record, python_record) for every fuzz case. Cached."""
    if get_backend() != "cpp":  # pragma: no cover - depends on build
        pytest.skip("compiled shannon._core not available; parity needs both backends")
    out = []
    for params, stream in _parity_cases():
        out.append(
            (
                params,
                stream,
                _run_parity("cpp", params, stream),
                _run_parity("python", params, stream),
            )
        )
    return tuple(out)


def _first_diff(cpp_seq, py_seq):
    for i, (a, b) in enumerate(zip(cpp_seq, py_seq)):
        if a != b:
            return i, a, b
    if len(cpp_seq) != len(py_seq):
        return min(len(cpp_seq), len(py_seq)), cpp_seq[len(py_seq) :], py_seq[len(cpp_seq) :]
    return None


class TestBackendParityFuzz:
    """C++ and pure-Python must agree exactly on randomised streams AND params."""

    def test_the_compiled_core_is_actually_under_test(self):
        # Without this, every test in this class could be comparing the Python
        # fallback with itself and passing for the emptiest of reasons.
        if get_backend() != "cpp":
            pytest.skip(
                "compiled shannon._core not available; pure-Python installs "
                "(SHANNON_SKIP_CORE=1 / Windows pure path) skip C++ parity gate"
            )
        det = ShannonCollapseDetector(window_size=4)
        assert det._cpp_detector is not None
        assert det.backend == "cpp"
        assert get_backend() == "cpp"

    def test_event_sequences_are_identical(self):
        for params, stream, (cpp, _, _), (py, _, _) in _parity_records():
            diff = _first_diff(cpp, py)
            assert diff is None, (
                f"(collapsed, expanded, oscillating, event, token_index) diverged at "
                f"token {diff[0]}: cpp={diff[1]} python={diff[2]}\n"
                f"params={params}\nstream={list(stream)}"
            )

    def test_callback_sequences_and_ordering_are_identical(self):
        for params, stream, (_, cpp_calls, _), (_, py_calls, _) in _parity_records():
            diff = _first_diff(cpp_calls, py_calls)
            assert diff is None, (
                f"callback stream diverged at position {diff[0]}: "
                f"cpp={diff[1]} python={diff[2]}\n"
                f"cpp fired {len(cpp_calls)}, python fired {len(py_calls)}\n"
                f"params={params}\nstream={list(stream)}"
            )

    def test_window_statistics_are_bit_identical(self):
        # ==, not approx. A tolerance here is what would let the population-vs-
        # sample variance bug (7% apart at window_size 8) hide again.
        for params, stream, (_, _, cpp_stats), (_, _, py_stats) in _parity_records():
            diff = _first_diff(cpp_stats, py_stats)
            assert diff is None, (
                f"(window_mean, window_std, delta, z_score) diverged at token "
                f"{diff[0]}:\n  cpp   ={diff[1]}\n  python={diff[2]}\n"
                f"params={params}\nstream={list(stream)}"
            )

    def test_the_fuzz_actually_exercises_every_event_type(self):
        # A parity suite that never produces an event proves nothing.
        wanted = {"none", "collapse", "expansion", "oscillation"}
        seen = set()
        for _, _, (cpp, _calls, _stats), _ in _parity_records():
            seen.update(row[3] for row in cpp)
        assert wanted <= seen, f"fuzz corpus never produced {wanted - seen}"

    def test_corpus_is_deterministic(self):
        # The seed is the reproducibility contract: a failure above must be
        # replayable verbatim on another machine.
        assert _parity_cases() == _parity_cases()
        assert _parity_cases()[0][1] == tuple(_parity_cases()[0][1])

    @pytest.mark.parametrize("case", range(0, _PARITY_CASES, 40))
    def test_full_pipeline_parity_through_add_logits(self, case):
        """Same, but through add_logits -- entropy kernel included.

        Uniform logits over 2**k states give exactly k bits on both backends
        (asserted below), so this compares the whole pipeline without depending
        on kernel round-off.
        """
        params, stream = _parity_cases()[case]
        bits = [int(min(12, max(0, round(h)))) for h in stream][:24]
        runs = {}
        for backend in ("cpp", "python"):
            det = ShannonCollapseDetector(**params)
            _pin_backend(det, backend)
            runs[backend] = [
                (r.entropy, r.collapsed, r.expanded, r.oscillating, r.event)
                for r in (det.add_logits(_uniform_logits(b)) for b in bits)
            ]
        assert [row[0] for row in runs["cpp"]] == [float(b) for b in bits], (
            "uniform logits no longer give exact bit values; this test's premise is gone"
        )
        assert runs["cpp"] == runs["python"]


class TestOscillationHistoryIsChronological:
    """The event history must be read oldest->newest, not in ring-buffer order.

    Both streams below are NON-periodic, 9 tokens, window_size 2 (so an event
    is decided purely by the step from the previous token) and
    oscillation_window 4. Both land their last token on an index where the old
    C++ ring buffer's array order was a rotation of the true history, and the
    expected verdicts are hand-computed from the definition -- "at least
    `min_alternations` collapse<->expansion transitions among the last
    `oscillation_window` events, in time order" -- not copied from either
    implementation. Parity alone would be satisfied by making Python adopt the
    C++ rotation; these pin the correct answer.
    """

    PARAMS = dict(window_size=2, threshold=-1.0, expansion_threshold=1.0, oscillation_window=4)

    # step:      -    0    0    0    0    0   -4   +4   -4
    # event:    N    N    N    N    N    N    C    E    C
    MISSED_ALARM = [10.0, 10.0, 10.0, 10.0, 10.0, 10.0, 6.0, 10.0, 6.0]
    # chronological last 4 = [N, C, E, C] -> 2 transitions -> OSCILLATION.
    # ring order at token 8 = [C(t8), N(t5), C(t6), E(t7)] -> 1 -> missed.

    # step:      -    0    0    0    0   +4   -4    0   -4
    # event:    N    N    N    N    N    E    C    N    C
    FALSE_ALARM = [10.0, 10.0, 10.0, 10.0, 10.0, 14.0, 10.0, 10.0, 6.0]
    # chronological last 4 = [E, C, N, C] -> 1 transition -> NOT oscillation.
    # ring order at token 8 = [C(t8), E(t5), C(t6), N(t7)] -> 2 -> false alarm.

    def _run(self, backend, stream):
        det = ShannonCollapseDetector(**self.PARAMS)
        _pin_backend(det, backend)
        return [det.push_entropy(h) for h in stream]

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_real_oscillation_is_not_lost_to_a_rotation(self, backend):
        results = self._run(backend, self.MISSED_ALARM)
        assert [r.event for r in results] == [
            "none",
            "none",
            "none",
            "none",
            "none",
            "none",
            "collapse",
            "expansion",
            "oscillation",
        ]
        assert results[-1].oscillating is True
        assert results[-1].collapsed is True, "oscillation must not erase the collapse verdict"

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_rotation_does_not_invent_an_oscillation(self, backend):
        results = self._run(backend, self.FALSE_ALARM)
        assert [r.event for r in results] == [
            "none",
            "none",
            "none",
            "none",
            "none",
            "expansion",
            "collapse",
            "none",
            "collapse",
        ]
        assert results[-1].oscillating is False
        assert results[-1].collapsed is True

    @pytest.mark.parametrize("stream_name", ["MISSED_ALARM", "FALSE_ALARM"])
    def test_backends_agree_on_both_streams(self, stream_name):
        stream = getattr(self, stream_name)
        cpp = [(r.collapsed, r.expanded, r.oscillating, r.event) for r in self._run("cpp", stream)]
        py = [
            (r.collapsed, r.expanded, r.oscillating, r.event) for r in self._run("python", stream)
        ]
        assert cpp == py

    def test_history_is_capped_at_the_oscillation_window(self):
        # An alternation that has aged out of the window must stop counting.
        # oscillation_window=4 and 4 quiet tokens after the flips => no event.
        stream = self.MISSED_ALARM + [6.0, 6.0, 6.0, 6.0]
        for backend in ("cpp", "python"):
            results = self._run(backend, stream)
            assert [r.event for r in results[-4:]] == ["none"] * 4


class TestWindowStatisticsAreNumericallyIdentical:
    """One arithmetic, two languages -- verified at an exact-threshold boundary.

    The 9-token stream below was found by fuzzing: at token 8 the window
    [0, 2, 8, 10, 12, 12, 5] has an exact mean of 7, so delta is exactly the
    -2.0 threshold and the verdict is decided by the last bit of the mean. The
    old Python running-sum mean returned exactly 7.0 there while the C++
    Welford returned 7.000000000000001 -- same window, different summation,
    ~9e-16 apart, opposite verdicts.

    This is NOT fixed with a tolerance on the flags. Both backends now evaluate
    the same Welford recurrence in the same order with FP contraction disabled,
    so they return the same double and therefore the same verdict. What remains
    is a property of that one shared algorithm: within ~1 ULP of the threshold
    the verdict is whatever the shared rounding says (here: fire). That is a
    documented, ~1e-15-wide band on ONE implementation, not a disagreement
    between two.
    """

    PARAMS = dict(window_size=7, threshold=-2.0, expansion_threshold=2.0, oscillation_window=3)
    STREAM = [5.0, 3.0, 0.0, 2.0, 8.0, 10.0, 12.0, 12.0, 5.0]

    def _run(self, backend):
        det = ShannonCollapseDetector(**self.PARAMS)
        _pin_backend(det, backend)
        return [det.push_entropy(h) for h in self.STREAM]

    def test_mean_and_std_are_bit_identical(self):
        cpp, py = self._run("cpp"), self._run("python")
        assert [r.window_mean for r in cpp] == [r.window_mean for r in py]
        assert [r.window_std for r in cpp] == [r.window_std for r in py]
        assert [r.delta for r in cpp] == [r.delta for r in py]
        assert [r.z_score for r in cpp] == [r.z_score for r in py]

    def test_at_threshold_verdict_agrees(self):
        cpp, py = self._run("cpp"), self._run("python")
        assert cpp[8].collapsed == py[8].collapsed
        assert cpp[8].delta == py[8].delta

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_variance_is_the_sample_variance(self, backend):
        # Pins the (n-1) denominator that C++ always used and Python did not.
        results = self._run(backend)
        window = self.STREAM[2:9]  # the 7 samples in the window at token 8
        mean = sum(window) / len(window)
        expected = math.sqrt(sum((x - mean) ** 2 for x in window) / (len(window) - 1))
        assert results[8].window_std == pytest.approx(expected, rel=1e-12)


class _TraceProbe(ShannonCollapseDetector):
    """Counts how many entropy values get copied out of the full trace."""

    def __init__(self, *args, **kwargs):
        self.trace_reads = 0
        self.trace_elements_copied = 0
        super().__init__(*args, **kwargs)

    @property
    def trace(self) -> list[float]:
        t = super().trace
        self.trace_reads += 1
        self.trace_elements_copied += len(t)
        return t


class TestCollapseEventWindowIsBounded:
    """Building CollapseEvent.window must cost O(window_size), not O(stream).

    _emit sliced the window off self.trace, whose getter returns a copy of the
    entire unbounded trace, so every collapse event cost O(total tokens seen).
    """

    WINDOW = 4

    def _drive(self, backend, n_tokens):
        events: list[CollapseEvent] = []
        det = _TraceProbe(window_size=self.WINDOW, threshold=-3.0, on_collapse=events.append)
        _pin_backend(det, backend)
        for _ in range(n_tokens):
            det.add_logits(_uniform_logits(10))
        det.add_logits(_uniform_logits(0))  # collapse
        return det, events

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_window_build_is_o_window_size(self, backend):
        det, events = self._drive(backend, 200)
        assert len(events) == 1
        budget = self.WINDOW * len(events)
        assert det.trace_elements_copied <= budget, (
            f"copied {det.trace_elements_copied} entropies to build "
            f"{len(events)} event window(s); budget is {budget}"
        )

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_window_build_cost_does_not_grow_with_stream_length(self, backend):
        short_det, short_events = self._drive(backend, 50)
        long_det, long_events = self._drive(backend, 500)
        assert len(short_events) == len(long_events) == 1
        assert short_det.trace_elements_copied == long_det.trace_elements_copied, (
            "per-event window cost scales with total stream length"
        )

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_window_content_is_unchanged(self, backend):
        _, events = self._drive(backend, 200)
        assert events[0].window == pytest.approx([10.0, 10.0, 10.0, 0.0])

    def test_window_content_matches_across_backends(self):
        _, cpp_events = self._drive("cpp", 20)
        _, py_events = self._drive("python", 20)
        assert cpp_events[0].window == pytest.approx(py_events[0].window)


# ── Fail-closed input policy on the event state machine ──────────────────────


class TestPushEntropyFailsClosed:
    """A non-finite entropy must be refused by BOTH backends, not absorbed.

    push_entropy is the one entry point that bypasses _validate_finite_1d, so
    it needs its own guard. A NaN in the window makes every `<` and `>` against
    the thresholds False for the next window_size tokens -- the detector goes
    quiet without a word, which is the worst possible failure for a safety
    gate. An infinity is worse still: it manufactures an event on the next
    token. Both refuse.
    """

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    @pytest.mark.parametrize("bad", [float("nan"), float("inf"), float("-inf")])
    def test_non_finite_entropy_raises(self, backend, bad):
        det = ShannonCollapseDetector(window_size=4)
        _pin_backend(det, backend)
        det.push_entropy(3.0)
        with pytest.raises(ValueError, match="finite"):
            det.push_entropy(bad)

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_the_window_is_untouched_by_a_rejected_value(self, backend):
        # Rejection must not half-apply: the trace and the statistics have to
        # look exactly as if the bad token had never been offered.
        det = ShannonCollapseDetector(window_size=4)
        _pin_backend(det, backend)
        for h in (10.0, 10.0, 10.0, 10.0):
            det.push_entropy(h)
        before = det.token_count, list(det.trace)
        with pytest.raises(ValueError):
            det.push_entropy(float("nan"))
        assert (det.token_count, list(det.trace)) == before
        # And the next real token is still judged against the clean window.
        r = det.push_entropy(0.0)
        assert r.collapsed is True
        assert math.isfinite(r.window_mean) and math.isfinite(r.window_std)

    @pytest.mark.parametrize(
        "kwargs,match",
        [
            (dict(window_size=0), "window_size must be a positive int"),
            (dict(window_size=-3), "window_size must be a positive int"),
            (dict(oscillation_window=0), "oscillation_window must be a positive int"),
            (dict(threshold=float("nan")), "threshold must be finite"),
            (dict(expansion_threshold=float("inf")), "expansion_threshold must be finite"),
            (dict(threshold=0.0), "threshold .collapse. must be negative"),
            (dict(threshold=1.0), "threshold .collapse. must be negative"),
            (dict(expansion_threshold=0.0), "expansion_threshold must be positive"),
            (dict(expansion_threshold=-1.0), "expansion_threshold must be positive"),
        ],
    )
    def test_malformed_parameters_are_refused_at_construction(self, kwargs, match):
        with pytest.raises(ValueError, match=match):
            ShannonCollapseDetector(**kwargs)

    def test_a_valid_construction_still_works(self):
        det = ShannonCollapseDetector(
            window_size=1, threshold=-0.1, expansion_threshold=0.1, oscillation_window=1
        )
        assert det.push_entropy(1.0) is not None


# ── Operator surface: env knobs, identical on both backends ──────────────────


class TestOperatorSurfaceParity:
    """SHANNON_* knobs must be parsed the same way by both backends.

    Each is read once, when a detector is constructed, so a test may set the
    variable and then build the detector. Nothing here depends on wall-clock
    time, a running daemon, or the order of anything.
    """

    OSC_STREAM = [10.0, 10.0, 10.0, 10.0, 6.0, 10.0, 6.0, 10.0, 6.0]
    OSC_PARAMS = dict(window_size=2, threshold=-1.0, expansion_threshold=1.0, oscillation_window=5)

    def _events(self, backend, **params):
        det = ShannonCollapseDetector(**{**self.OSC_PARAMS, **params})
        _pin_backend(det, backend)
        return [det.push_entropy(h).event for h in self.OSC_STREAM]

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_default_min_alternations_is_two(self, backend, monkeypatch):
        monkeypatch.delenv("SHANNON_OSCILLATION_MIN_ALTERNATIONS", raising=False)
        det = ShannonCollapseDetector(window_size=4)
        _pin_backend(det, backend)
        assert det.min_alternations == 2
        assert "oscillation" in self._events(backend)

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_raising_min_alternations_suppresses_the_label(self, backend, monkeypatch):
        # The knob is enforced, not decorative: this stream accumulates at most
        # 4 transitions inside the window, so requiring 5 leaves nothing
        # labelled oscillating -- while the collapse/expansion verdicts
        # underneath are untouched.
        monkeypatch.setenv("SHANNON_OSCILLATION_MIN_ALTERNATIONS", "5")
        events = self._events(backend)
        assert "oscillation" not in events
        assert "collapse" in events and "expansion" in events

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_lowering_min_alternations_makes_it_more_sensitive(self, backend, monkeypatch):
        monkeypatch.setenv("SHANNON_OSCILLATION_MIN_ALTERNATIONS", "1")
        events = self._events(backend)
        assert events.count("oscillation") > self._events_with(backend, "2").count("oscillation")

    def _events_with(self, backend, value):
        import os

        old = os.environ.get("SHANNON_OSCILLATION_MIN_ALTERNATIONS")
        os.environ["SHANNON_OSCILLATION_MIN_ALTERNATIONS"] = value
        try:
            return self._events(backend)
        finally:
            if old is None:
                os.environ.pop("SHANNON_OSCILLATION_MIN_ALTERNATIONS", None)
            else:
                os.environ["SHANNON_OSCILLATION_MIN_ALTERNATIONS"] = old

    @pytest.mark.parametrize("value", ["3", " 3 ", "+3"])
    def test_both_backends_read_the_same_value(self, value, monkeypatch):
        monkeypatch.setenv("SHANNON_OSCILLATION_MIN_ALTERNATIONS", value)
        assert self._events("cpp") == self._events("python")
        det = ShannonCollapseDetector(window_size=4)
        assert det.min_alternations == 3

    @pytest.mark.parametrize("bad", ["0", "-1", "two", "2.5", "", "  ", "1_0", "3x"])
    def test_a_malformed_knob_refuses_to_start(self, bad, monkeypatch):
        # Blank is treated as unset (documented); everything else raises rather
        # than silently reverting to stock sensitivity.
        monkeypatch.setenv("SHANNON_OSCILLATION_MIN_ALTERNATIONS", bad)
        if bad.strip() == "":
            assert ShannonCollapseDetector(window_size=4).min_alternations == 2
        else:
            with pytest.raises(ValueError, match="SHANNON_OSCILLATION_MIN_ALTERNATIONS"):
                ShannonCollapseDetector(window_size=4)

    @pytest.mark.parametrize("bad", ["maybe", "2", "yes please"])
    def test_a_malformed_observe_flag_refuses_to_start(self, bad, monkeypatch):
        monkeypatch.setenv("SHANNON_DETECTOR_OBSERVE_ONLY", bad)
        with pytest.raises(ValueError, match="SHANNON_DETECTOR_OBSERVE_ONLY"):
            ShannonCollapseDetector(window_size=4)


class TestObserveOnlyMode:
    """Observe-only measures without acting -- and is off unless asked for."""

    STREAM = [10.0, 10.0, 10.0, 10.0, 0.0, 10.0, 0.0, 10.0, 0.0]
    PARAMS = dict(window_size=4, threshold=-3.0, expansion_threshold=3.0, oscillation_window=5)

    def _run(self, backend):
        results, events = [], []
        det = ShannonCollapseDetector(
            callback=results.append, on_collapse=events.append, **self.PARAMS
        )
        _pin_backend(det, backend)
        classified = [det.push_entropy(h) for h in self.STREAM]
        return det, classified, results, events

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_enforcement_is_the_default(self, backend, monkeypatch):
        monkeypatch.delenv("SHANNON_DETECTOR_OBSERVE_ONLY", raising=False)
        det, classified, results, events = self._run(backend)
        assert det.observe_only is False
        assert results, "callbacks must fire by default"
        assert events, "legacy on_collapse must fire by default"
        assert det.suppressed_events == 0

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    @pytest.mark.parametrize("value", ["1", "true", "YES", "on"])
    def test_observe_only_withholds_every_callback(self, backend, value, monkeypatch):
        monkeypatch.setenv("SHANNON_DETECTOR_OBSERVE_ONLY", value)
        det, classified, results, events = self._run(backend)
        assert det.observe_only is True
        assert results == [], "a callback fired while the detector was observe-only"
        assert events == [], "legacy on_collapse fired while the detector was observe-only"

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_classification_is_unaffected_by_observe_only(self, backend, monkeypatch):
        monkeypatch.delenv("SHANNON_DETECTOR_OBSERVE_ONLY", raising=False)
        _, enforcing, _, _ = self._run(backend)
        monkeypatch.setenv("SHANNON_DETECTOR_OBSERVE_ONLY", "1")
        det, observing, _, _ = self._run(backend)
        assert [(r.collapsed, r.expanded, r.oscillating, r.event) for r in observing] == [
            (r.collapsed, r.expanded, r.oscillating, r.event) for r in enforcing
        ]
        # ...and the withheld callbacks are counted, which is the number an
        # operator sizes the rollout on.
        assert det.suppressed_events == sum(
            1 for r in enforcing if r.collapsed or r.expanded or r.oscillating
        )
        assert det.suppressed_events > 0

    def test_both_backends_suppress_identically(self, monkeypatch):
        monkeypatch.setenv("SHANNON_DETECTOR_OBSERVE_ONLY", "1")
        cpp_det, cpp_res, cpp_cb, cpp_ev = self._run("cpp")
        py_det, py_res, py_cb, py_ev = self._run("python")
        assert (cpp_cb, cpp_ev) == (py_cb, py_ev) == ([], [])
        assert cpp_det.suppressed_events == py_det.suppressed_events
        assert [r.event for r in cpp_res] == [r.event for r in py_res]

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_reset_clears_the_suppressed_counter(self, backend, monkeypatch):
        monkeypatch.setenv("SHANNON_DETECTOR_OBSERVE_ONLY", "1")
        det, _, _, _ = self._run(backend)
        assert det.suppressed_events > 0
        det.reset()
        assert det.suppressed_events == 0
