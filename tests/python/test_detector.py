# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""Tests for the Shannon entropy collapse detector (Python)."""

import math

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

    def test_both_backends_fire_identical_callback_counts(self):
        cpp_events, cpp_results, _ = self._run("cpp")
        py_events, py_results, _ = self._run("python")

        assert len(cpp_events) == len(py_events), (
            f"on_collapse fired {len(cpp_events)}x on cpp vs {len(py_events)}x on python "
            f"for an identical stream"
        )
        assert len(cpp_events) > 1, "collapses inside an oscillating stretch never fired"
        assert len(cpp_results) == len(py_results)

    def test_both_backends_report_identical_flags(self):
        _, _, cpp_flags = self._run("cpp")
        _, _, py_flags = self._run("python")
        assert cpp_flags == py_flags

    @pytest.mark.parametrize("backend", ["cpp", "python"])
    def test_oscillation_does_not_clear_the_threshold_verdict(self, backend):
        _, results, _ = self._run(backend)
        oscillating = [r for r in results if r.event == "oscillation"]
        assert oscillating, "stream did not oscillate"
        # Every oscillating token is still either a collapse or an expansion:
        # OSCILLATION labels the pattern, it does not erase the verdict.
        assert all(r.collapsed or r.expanded for r in oscillating)
        assert any(r.collapsed for r in oscillating)


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
