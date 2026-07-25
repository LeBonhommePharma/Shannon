# =============================================================================
# ShannonCollapseDetector — Main Python API for LLM Entropy Monitoring
#
# White-box physicochemical referee for LLM safeguarding.
# Detects "entropy collapse" — when an LLM's token distribution locks
# into a single dominant state (analogous to configurational entropy
# collapse in molecular docking).
#
# Features:
#   - Z-score based collapse/expansion/oscillation detection
#   - Welford window statistics, bit-identical to the C++ core
#   - FastOPTICS super-clustering on collapse (optional)
#   - C++ acceleration with Python fallback
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import dataclasses
import math
import os
import re
from collections import deque
from typing import Callable

import numpy as np
from numpy.typing import ArrayLike

from shannon._numba_fallback import (
    _ensure_float64_1d,
    shannon_configurational_entropy,
    shannon_entropy_from_logits as _entropy_from_logits,
    shannon_entropy as _entropy_from_probs,
    shannon_entropy_from_logprobs as _entropy_from_logprobs,
)

DEFAULT_WINDOW_SIZE = 8
DEFAULT_COLLAPSE_THRESHOLD = -3.2  # bits (delta below window mean)
DEFAULT_EXPANSION_THRESHOLD = +3.2  # bits (delta above window mean)
DEFAULT_OSCILLATION_WINDOW = 5

# Default number of collapse<->expansion transitions inside the oscillation
# window before a token is labelled "oscillation". Mirrored in
# src/shannon/collapse_detector.cpp; both backends must agree.
DEFAULT_MIN_ALTERNATIONS = 2

# ── Operator surface ─────────────────────────────────────────────────────────
#
# Two env knobs, read ONCE per constructed detector (so a test or a supervisor
# can set them and build a fresh detector, and so nothing changes underneath a
# running stream). The compiled C++ core parses the same two variables with the
# same rules in its constructor — TestOperatorSurfaceParity pins the two
# parsers to identical answers.
#
#   SHANNON_OSCILLATION_MIN_ALTERNATIONS   default 2, minimum 1
#       How many collapse<->expansion flips must appear inside
#       ``oscillation_window`` before a token is reported as oscillating.
#       Symptom -> action: oscillation firing on ordinary traffic -> raise to 3
#       or 4; known flip-flopping agent slipping through -> lower to 1 (any
#       single flip then oscillates).
#
#   SHANNON_DETECTOR_OBSERVE_ONLY          default 0 (enforce)
#       "1"/"true"/"yes"/"on": still classify every token and still return a
#       fully populated CollapseResult, but never invoke a callback. Nothing
#       downstream (handrail, kill switch, alerting) is triggered. Use it to
#       measure how often a new threshold WOULD fire on live traffic before
#       letting it act: ``detector.suppressed_events`` counts exactly the
#       callbacks that were withheld. Enforcement is the default, because a
#       detector that ships in observe mode by accident is a detector that
#       never fires.
#
# Both refuse to start on a value they cannot parse rather than silently using
# the default: a typo in a safety knob must not quietly restore stock
# sensitivity while the operator believes it was retuned.

_TRUE_TOKENS = frozenset({"1", "true", "yes", "on"})
_FALSE_TOKENS = frozenset({"0", "false", "no", "off"})
_INT_RE = re.compile(r"^[+-]?[0-9]+$")


def _env_flag(name: str, default: bool) -> bool:
    """Parse a boolean SHANNON_* env var; raise ValueError on anything else."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    token = raw.strip().lower()
    if not token:  # blank behaves as unset, matching getenv-with-empty in C++
        return default
    if token in _TRUE_TOKENS:
        return True
    if token in _FALSE_TOKENS:
        return False
    raise ValueError(
        f"{name}: expected one of 1/0/true/false/yes/no/on/off, got {raw!r}; "
        f"refusing to start with an ambiguous enforcement mode"
    )


def _env_positive_int(name: str, default: int) -> int:
    """Parse an integer >= 1 SHANNON_* env var; raise ValueError on anything else."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    token = raw.strip()
    if not token:
        return default
    if not _INT_RE.match(token) or int(token) < 1:
        raise ValueError(
            f"{name}: expected an integer >= 1, got {raw!r}; refusing to start "
            f"with an unknown oscillation sensitivity"
        )
    return int(token)


def _welford_window_stats(window: deque[float] | list[float]) -> tuple[float, float]:
    """Return (mean, sample stddev) of the window, oldest sample first.

    Byte-for-byte twin of ``welford_window_stats`` in
    ``src/shannon/collapse_detector.cpp``. The two must stay identical
    operation-for-operation, not merely mathematically equivalent:

    * Welford, not ``E[X**2] - E[X]**2``. The old running-sum form here
      cancelled catastrophically near H ~ 2 bits and drifted from the C++ mean
      by ~1e-15 after a few hundred tokens, which flipped ``.collapsed`` on any
      token whose delta landed exactly on the threshold (the audit's 1/400
      ``.collapsed`` and 5/400 ``.expanded`` divergences, and all 6/400
      callback-count divergences).
    * SAMPLE variance, ``M2 / (count - 1)``. The old form divided by ``count``
      while C++ divided by ``count - 1``, so ``window_std`` and ``z_score``
      disagreed between the backends on *every* token -- a divergence the
      flags-only fuzz never saw because neither flag reads the std.
    * Oldest-first iteration. Same numbers in a different order round
      differently; C++ walks its ring buffer from the oldest slot for exactly
      this reason.

    Both backends are compared with ``==`` (not ``approx``) in
    ``tests/python/test_detector.py::TestBackendParityFuzz``.
    """
    mean = 0.0
    m2 = 0.0
    count = 0
    for x in window:
        count += 1
        delta = x - mean
        mean += delta / count
        delta2 = x - mean
        m2 += delta * delta2
    variance = m2 / (count - 1) if count > 1 else 0.0
    return mean, math.sqrt(max(0.0, variance))


@dataclasses.dataclass(frozen=True, slots=True)
class CollapseResult:
    """Result from a single step of entropy event detection."""

    entropy: float
    """Current token entropy (bits)."""

    window_mean: float
    """Mean entropy over the sliding window."""

    window_std: float
    """Standard deviation of entropy over the window."""

    delta: float
    """entropy - window_mean (negative = collapse, positive = expansion)."""

    z_score: float
    """Standardised score: delta / window_std."""

    collapsed: bool
    """True if the entropy dropped below collapse threshold."""

    expanded: bool
    """True if the entropy rose above expansion threshold."""

    oscillating: bool
    """True if rapid collapse/expand alternation detected."""

    event: str
    """Classified event: 'none', 'collapse', 'expansion', or 'oscillation'."""

    token_index: int
    """0-based token counter."""


CollapseCallback = Callable[[CollapseResult], None]


def _validate_finite_1d(arr: np.ndarray, method: str, kind: str) -> np.ndarray:
    """Reject empty and non-finite input before any entropy computation.

    For a safety library, H=0.0 is the *alarm* condition ("total collapse").
    Silently returning H=0.0 on garbage input (NaN/Inf logit, empty array)
    would manufacture the exact signal the tool exists to detect — or mask a
    real one. So we refuse instead, with an actionable message, BEFORE
    dispatching to either the C++ or the Python backend so both paths behave
    identically. ``np.isfinite(...).all()`` is a fast, vectorized single pass.

    A single finite element (n == 1) is valid — the one-hot fallback in the
    streaming integrations relies on it — so the empty check is n == 0.
    """
    if arr.size == 0:
        raise ValueError(
            f"{method}: input is empty; refusing to compute entropy on a "
            f"zero-length {kind} array (H=0.0 is the collapse alarm, not a "
            f"valid answer for empty input)"
        )
    if not np.isfinite(arr).all():
        bad = np.flatnonzero(~np.isfinite(arr))
        idx = int(bad[0])
        val = arr[idx]
        kw = "NaN" if np.isnan(val) else ("+Inf" if val > 0 else "-Inf")
        raise ValueError(
            f"{method}: input contains {kw} at index {idx}; refusing to "
            f"compute entropy on non-finite {kind} ({bad.size} non-finite "
            f"element(s) total)"
        )
    return arr


def _validate_detector_params(
    window_size: int,
    threshold: float,
    expansion_threshold: float,
    oscillation_window: int,
) -> None:
    """Refuse detector parameters that would silently disarm the detector.

    Every case below used to be accepted by one backend and quietly rewritten
    or crashed by the other:

    * ``window_size <= 0``  -- Python raised IndexError on the second token
      while C++ silently substituted 8, so the same call produced a working
      detector with the WRONG window on one backend and an exception on the
      other.
    * ``oscillation_window <= 0`` -- ``deque(maxlen=0)`` keeps no history at
      all, so oscillation can never be reported; C++ silently substituted 5.
    * A NaN threshold -- every ``<``/``>`` against NaN is False, i.e. the
      detector is off, silently and permanently.
    * ``threshold >= 0`` / ``expansion_threshold <= 0`` -- these inverted
      thresholds fire on essentially every token, which is how a gate ends up
      switched off by an operator drowning in alerts.
    """
    if not isinstance(window_size, int) or window_size <= 0:
        raise ValueError(f"window_size must be a positive int, got {window_size!r}")
    if not isinstance(oscillation_window, int) or oscillation_window <= 0:
        raise ValueError(
            f"oscillation_window must be a positive int, got {oscillation_window!r}; "
            f"0 keeps no event history, so oscillation could never be detected"
        )
    for name, value in (("threshold", threshold), ("expansion_threshold", expansion_threshold)):
        if not math.isfinite(value):
            raise ValueError(
                f"{name} must be finite, got {value!r}; every comparison against "
                f"NaN is False, which silently disables detection"
            )
    if threshold >= 0:
        raise ValueError(
            f"threshold (collapse) must be negative -- it is compared as "
            f"delta < threshold with delta = entropy - window_mean -- got {threshold!r}"
        )
    if expansion_threshold <= 0:
        raise ValueError(
            f"expansion_threshold must be positive -- it is compared as "
            f"delta > expansion_threshold -- got {expansion_threshold!r}"
        )


@dataclasses.dataclass(frozen=True, slots=True)
class CollapseEvent:
    """Fired when entropy collapse is detected (for streaming integrations)."""

    token_index: int
    entropy: float
    delta_h: float
    collapse_score: float
    window: list[float]


@dataclasses.dataclass(frozen=True, slots=True)
class SuperClusterInfo:
    """Result of FastOPTICS super-clustering on collapse."""

    cluster_id: int
    n_members: int
    centroid: list[float]
    radius: float
    active_types: list[int]


class _PyFastOPTICS:
    """Pure-Python FastOPTICS for super-cluster extraction (fallback).

    Simplified implementation using k-means as a proxy when the C++ FastOPTICS
    is not available. For production, the C++ implementation is preferred.
    """

    def __init__(self, min_pts: int = 5, n_clusters_hint: int = 3):
        self._min_pts = min_pts
        self._n_clusters_hint = n_clusters_hint

    def cluster(self, vectors: np.ndarray) -> list[SuperClusterInfo]:
        """Cluster 256-d row vectors to find super-clusters."""
        n = len(vectors)
        if n < self._min_pts:
            return []

        k = min(self._n_clusters_hint, n // self._min_pts)
        if k < 1:
            k = 1

        # Initialize centroids (k-means++)
        rng = np.random.default_rng(42)
        centroids = [vectors[rng.integers(n)].copy()]
        for _ in range(1, k):
            dists = np.array([min(np.sum((v - c) ** 2) for c in centroids) for v in vectors])
            probs = dists / (dists.sum() + 1e-15)
            idx = rng.choice(n, p=probs)
            centroids.append(vectors[idx].copy())

        # Iterate
        for _ in range(20):
            # Assign
            labels = np.array(
                [min(range(k), key=lambda c: np.sum((v - centroids[c]) ** 2)) for v in vectors]
            )
            # Update
            for c in range(k):
                mask = labels == c
                if mask.any():
                    centroids[c] = vectors[mask].mean(axis=0)

        # Build results
        results = []
        for c in range(k):
            mask = labels == c
            members = np.where(mask)[0]
            if len(members) < self._min_pts:
                continue
            centroid = centroids[c]
            dists = np.sqrt(np.sum((vectors[members] - centroid) ** 2, axis=1))
            radius = float(dists.max()) if len(dists) > 0 else 0.0
            results.append(
                SuperClusterInfo(
                    cluster_id=c,
                    n_members=len(members),
                    centroid=centroid.tolist(),
                    radius=radius,
                    active_types=members.tolist(),
                )
            )

        # Sort by size (largest first = dominant super-cluster)
        results.sort(key=lambda x: x.n_members, reverse=True)
        return results


class ShannonCollapseDetector:
    """Real-time Shannon entropy collapse detector for LLM token streams.

    Monitors the entropy of token probability distributions and detects sudden
    collapse — the information-theoretic analogue of configurational entropy
    collapse in molecular docking.

    Supports three event types:
      - **collapse**: entropy drops far below window mean (delta < threshold)
      - **expansion**: entropy rises far above window mean (delta > expansion_threshold)
      - **oscillation**: rapid alternation between collapse and expansion

    Optionally triggers FastOPTICS super-clustering on collapse detection.

    Parameters
    ----------
    window_size : int
        Number of recent entropy values to track (default: 8).
    threshold : float
        Collapse threshold in bits. A token is flagged when its entropy
        drops more than this amount below the window mean (default: -3.2).
    expansion_threshold : float
        Expansion threshold in bits (default: +3.2).
    oscillation_window : int
        Window for detecting collapse/expansion alternation (default: 5).
    callback : callable, optional
        Function called on every collapse/expansion/oscillation event.
    enable_clustering : bool
        Enable FastOPTICS super-clustering on collapse (default: False).
    collapse_threshold : float, optional
        Alias for ``threshold`` (backwards compat). Ignored when ``threshold``
        is also provided.

    Environment
    -----------
    ``SHANNON_OSCILLATION_MIN_ALTERNATIONS`` (default 2) and
    ``SHANNON_DETECTOR_OBSERVE_ONLY`` (default 0 = enforce) are read once here,
    at construction. See the module-level "Operator surface" block for what to
    do with each. Malformed values raise ValueError instead of falling back to
    the default.

    Raises
    ------
    ValueError
        On a parameter that cannot describe a working detector: a non-positive
        ``window_size`` or ``oscillation_window``, a non-finite threshold, a
        non-negative collapse ``threshold`` or a non-positive
        ``expansion_threshold``. Each of those silently disables part of the
        detection (an ``oscillation_window`` of 0, for instance, empties the
        event history so oscillation can never fire), so construction refuses
        rather than handing back a detector that looks armed and is not.

    Examples
    --------
    >>> detector = ShannonCollapseDetector()
    >>> result = detector.add_logits(np.random.randn(50000))
    >>> print(f"Entropy: {result.entropy:.2f} bits, event: {result.event}")
    """

    def __init__(
        self,
        window_size: int = DEFAULT_WINDOW_SIZE,
        threshold: float = DEFAULT_COLLAPSE_THRESHOLD,
        expansion_threshold: float = DEFAULT_EXPANSION_THRESHOLD,
        oscillation_window: int = DEFAULT_OSCILLATION_WINDOW,
        callback: CollapseCallback | None = None,
        enable_clustering: bool = False,
        # Backwards compat aliases
        collapse_threshold: float | None = None,
        on_collapse: Callable[[CollapseEvent], None] | None = None,
    ):
        # Handle backwards-compat parameter names
        if collapse_threshold is not None:
            threshold = collapse_threshold

        _validate_detector_params(window_size, threshold, expansion_threshold, oscillation_window)

        # Operator knobs. Parsed BEFORE the C++ core is constructed so a
        # malformed value reports the actionable Python message rather than the
        # std::invalid_argument the C++ constructor would raise a line later.
        self._min_alternations = _env_positive_int(
            "SHANNON_OSCILLATION_MIN_ALTERNATIONS", DEFAULT_MIN_ALTERNATIONS
        )
        self._observe_only = _env_flag("SHANNON_DETECTOR_OBSERVE_ONLY", False)
        self._suppressed_events = 0

        # These two are deliberately NOT merged. `callback` is handed a
        # CollapseResult; the legacy `on_collapse` is handed a CollapseEvent.
        # Assigning `callback or on_collapse` conflated them, so a caller who
        # passed only on_collapse had their CollapseEvent handler invoked with a
        # CollapseResult -- an AttributeError on the first access of delta_h,
        # collapse_score or window, none of which CollapseResult has.
        self._callback = callback
        self._on_collapse_event = on_collapse  # Separate CollapseEvent callback

        self._window_size = window_size
        self._threshold = threshold
        self._expansion_threshold = expansion_threshold
        self._oscillation_window = oscillation_window
        self._enable_clustering = enable_clustering

        self._trace: list[float] = []
        self._window: deque[float] = deque(maxlen=window_size)
        # Last `window_size` entropies EXCLUDING the token currently being
        # emitted — the O(window_size) source for CollapseEvent.window.
        # Both backends maintain it: the pure-Python path appends after
        # _emit, and the C++ path appends when add_*() returns, because its
        # callback fires from inside the C++ call, before Python ever sees
        # the value. _emit appends the current entropy itself.
        self._recent: deque[float] = deque(maxlen=window_size)
        self._event_history: deque[str] = deque(maxlen=oscillation_window)
        self._token_count = 0

        # C++ detector (optional fast path) — the v2 engine bound in
        # shannon._core. (This previously imported `_shannon_cpp`, a module
        # that never existed, so the fast path could never activate.)
        self._cpp_detector = None
        try:
            from shannon._core import CollapseDetector as CppDetector

            self._cpp_detector = CppDetector(
                window_size, threshold, expansion_threshold, oscillation_window
            )
            if self._callback is not None or self._on_collapse_event is not None:
                # Wrap so Python callbacks receive the Python CollapseResult
                # dataclass, not the raw C++ binding object, then dispatch
                # through _emit so this fast path fires exactly the same
                # callbacks as the pure-Python path. Previously it invoked
                # self._callback directly and never fired _on_collapse_event at
                # all, so the legacy on_collapse API was silently dead whenever
                # the C++ core was present -- i.e. by default.
                self._cpp_detector.set_callback(self._on_cpp_event)
        except ImportError:
            pass

        # Super-clustering (optional)
        self._last_super_cluster: SuperClusterInfo | None = None
        self._active_types: list[int] = []
        if enable_clustering:
            self._clusterer = _PyFastOPTICS()

        # Last result seen from either backend — keeps the convenience
        # properties (is_collapsed, collapse_score, …) truthful on the
        # C++ fast path, which bypasses the Python window state.
        self._last_result: CollapseResult | None = None

        # Backend label
        try:
            from shannon._core import SlidingWindowEntropy  # noqa: F401

            self._backend = "cpp"
        except ImportError:
            self._backend = "python"

    def reset(self) -> None:
        """Clear all internal state."""
        if self._cpp_detector is not None:
            self._cpp_detector.reset()
        self._trace.clear()
        self._window.clear()
        self._recent.clear()
        self._event_history.clear()
        self._token_count = 0
        self._last_super_cluster = None
        self._active_types.clear()
        self._last_result = None
        self._suppressed_events = 0

    def add_logits(self, logits: ArrayLike) -> CollapseResult:
        """Feed raw logits for the current token.

        Returns CollapseResult with full event classification.
        """
        arr = _validate_finite_1d(_ensure_float64_1d(logits), "add_logits", "logits")
        if self._cpp_detector is not None:
            return self._record_cpp(self._cpp_detector.add_logits(arr))
        h = shannon_configurational_entropy(arr)
        result = self._push(h)

        # Track active types for clustering
        if self._enable_clustering:
            top_k = min(20, len(arr))
            top_indices = np.argpartition(arr, -top_k)[-top_k:]
            self._active_types.extend(int(i % 256) for i in top_indices)
            if len(self._active_types) > 1000:
                self._active_types = self._active_types[-500:]

        return result

    def add_probs(self, probs: ArrayLike) -> CollapseResult:
        """Feed a normalized probability distribution."""
        arr = _validate_finite_1d(_ensure_float64_1d(probs), "add_probs", "probabilities")
        if self._cpp_detector is not None:
            return self._record_cpp(self._cpp_detector.add_probs(arr))
        h = _entropy_from_probs(arr)
        return self._push(h)

    def add_logprobs(self, logprobs: ArrayLike) -> CollapseResult:
        """Feed log-probabilities (base e)."""
        arr = _validate_finite_1d(_ensure_float64_1d(logprobs), "add_logprobs", "logprobs")
        if self._cpp_detector is not None:
            return self._record_cpp(self._cpp_detector.add_logprobs(arr))
        h = _entropy_from_logprobs(arr)
        return self._push(h)

    def push_entropy(self, h: float) -> CollapseResult:
        """Feed a pre-computed entropy value (bits) for the current token.

        The public twin of ``CollapseDetector::push_entropy`` in the C++ core,
        and the only entry point that exercises the event state machine on its
        own -- no entropy kernel in front of it. Callers that already have an
        entropy (a proxy gate, a replayed trace, a parity test) should use this
        rather than synthesising logits.

        Raises ValueError on a non-finite value, on both backends: NaN would
        make every threshold comparison False for the next ``window_size``
        tokens, silently disarming the detector.
        """
        h = float(h)
        if self._cpp_detector is not None:
            if not math.isfinite(h):
                # Pre-checked so the message is identical on both backends;
                # the C++ core rejects it too if this is ever bypassed.
                raise ValueError(
                    f"push_entropy: entropy must be finite, got {h!r}; refusing "
                    f"to admit a non-finite value into the sliding window"
                )
            return self._record_cpp(self._cpp_detector.push_entropy(h))
        return self._push(h)

    @property
    def trace(self) -> list[float]:
        """Full entropy trace (all tokens seen so far)."""
        if self._cpp_detector is not None:
            return list(self._cpp_detector.trace)
        return list(self._trace)

    @property
    def entropy_trace(self) -> list[float]:
        """Alias for trace."""
        return self.trace

    @property
    def window_size(self) -> int:
        return self._window_size

    @property
    def threshold(self) -> float:
        return self._threshold

    @property
    def is_collapsed(self) -> bool:
        """Whether the most recent token triggered a collapse event."""
        if self._last_result is not None:
            return self._last_result.event in ("collapse", "oscillation")
        return False

    @property
    def collapse_score(self) -> float:
        """|delta / threshold|, >1.0 means collapsed."""
        if abs(self._threshold) < 1e-15 or self._last_result is None:
            return 0.0
        return abs(self._last_result.delta / self._threshold)

    @property
    def current_entropy(self) -> float:
        """Most recent entropy value."""
        if self._last_result is not None:
            return self._last_result.entropy
        return self._trace[-1] if self._trace else 0.0

    @property
    def delta_h(self) -> float:
        """Rate of entropy change via linear regression over the window.

        On the C++ fast path the Python window is not populated, so this
        falls back to the last deviation-from-window-mean (delta).
        """
        n = len(self._window)
        if n < 2:
            if self._last_result is not None:
                return self._last_result.delta
            return 0.0
        sum_i = 0.0
        sum_h = 0.0
        sum_ih = 0.0
        sum_i2 = 0.0
        for i, h in enumerate(self._window):
            fi = float(i)
            sum_i += fi
            sum_h += h
            sum_ih += fi * h
            sum_i2 += fi * fi
        fn = float(n)
        denom = fn * sum_i2 - sum_i * sum_i
        if abs(denom) < 1e-15:
            return 0.0
        return (fn * sum_ih - sum_i * sum_h) / denom

    @property
    def token_count(self) -> int:
        """Total number of tokens processed."""
        if self._cpp_detector is not None:
            return self._cpp_detector.token_count
        return self._token_count

    @property
    def backend(self) -> str:
        """Active computation backend: 'cpp' or 'python'."""
        return self._backend

    @property
    def observe_only(self) -> bool:
        """True when SHANNON_DETECTOR_OBSERVE_ONLY held this detector's callbacks.

        Classification is unaffected; only delivery to the callbacks is.
        """
        return self._observe_only

    @property
    def min_alternations(self) -> int:
        """Collapse<->expansion flips required inside the oscillation window.

        From SHANNON_OSCILLATION_MIN_ALTERNATIONS (default 2).
        """
        return self._min_alternations

    @property
    def suppressed_events(self) -> int:
        """Callbacks withheld so far because observe-only mode is on.

        This is the number a deployment should look at before enforcing: it is
        exactly how many times the handrail would have been invoked. Always 0
        when observe_only is False. Cleared by reset().
        """
        return self._suppressed_events

    @property
    def super_cluster(self) -> SuperClusterInfo | None:
        """Most recent super-cluster from FastOPTICS (None if not triggered)."""
        return self._last_super_cluster

    def _push(self, h: float) -> CollapseResult:
        """Push an entropy value through the Python fallback detector."""
        if not math.isfinite(h):
            # Fail closed, identically to CollapseDetector::push_entropy in C++.
            # A NaN entropy poisons the window for window_size tokens and makes
            # every threshold comparison False -- it switches the detector off
            # without a word. An infinity manufactures an event on the next
            # token. Neither is admitted.
            raise ValueError(
                f"push_entropy: entropy must be finite, got {h!r}; refusing to "
                f"admit a non-finite value into the sliding window"
            )

        self._trace.append(h)
        self._window.append(h)

        # Window statistics: the shared Welford recurrence, oldest sample
        # first. Deliberately O(window_size) rather than the O(1) running-sum
        # form that used to live here -- see _welford_window_stats for why the
        # running sums had to go (they drifted from the C++ mean by ~1e-15 and
        # used a different variance denominator). window_size is 8 by default;
        # this is nanoseconds next to computing the entropy itself.
        count = len(self._window)
        mean, std = _welford_window_stats(self._window)

        delta = h - mean
        z = delta / std if std > 1e-12 else 0.0
        window_ready = count >= self._window_size

        collapsed = window_ready and (delta < self._threshold)
        expanded = window_ready and (delta > self._expansion_threshold)

        event = "none"
        if collapsed:
            event = "collapse"
        elif expanded:
            event = "expansion"

        # Chronological, oldest first, capped at oscillation_window. The C++
        # twin keeps the same shape (a deque, grown from empty) -- it used to
        # keep a ring buffer indexed by token_count and read it in ARRAY order,
        # i.e. a rotation of this list, which invents an adjacency between the
        # newest and the oldest event. That disagreed with this loop on 289/400
        # fuzzed streams.
        self._event_history.append(event)

        oscillating = False
        if window_ready and event != "none":
            alternations = 0
            prev = list(self._event_history)
            for i in range(1, len(prev)):
                if (prev[i - 1] == "collapse" and prev[i] == "expansion") or (
                    prev[i - 1] == "expansion" and prev[i] == "collapse"
                ):
                    alternations += 1
            if alternations >= self._min_alternations:
                oscillating = True
                event = "oscillation"

        result = CollapseResult(
            entropy=h,
            window_mean=mean,
            window_std=std,
            delta=delta,
            z_score=z,
            collapsed=collapsed,
            expanded=expanded,
            oscillating=oscillating,
            event=event,
            token_index=self._token_count,
        )
        self._last_result = result
        self._token_count += 1

        self._count_if_suppressed(result)
        self._emit(result)
        # After _emit: _recent holds the window *excluding* the token being
        # emitted, which is the invariant the C++ path can also honour.
        self._recent.append(h)

        # Trigger super-clustering on collapse
        if collapsed and self._enable_clustering:
            self._run_clustering()

        return result

    def _emit(self, result: CollapseResult) -> None:
        """Deliver one result to both callback flavours.

        The single dispatch point for both backends. `callback` receives the
        CollapseResult; the legacy `on_collapse` receives a CollapseEvent built
        from it. Funnelling the C++ fast path and the pure-Python path through
        here is what stops the two from disagreeing about which callbacks fire
        and with what type -- the previous split let the C++ path drop
        on_collapse entirely.

        Under SHANNON_DETECTOR_OBSERVE_ONLY no callback is delivered at all:
        classification still happened and the result is still returned to the
        caller, but nothing downstream is allowed to act on it. The C++ core
        applies the same rule at its own callback site, so neither backend can
        act while the other only watches.
        """
        if self._observe_only:
            return
        if (
            result.collapsed or result.expanded or result.oscillating
        ) and self._callback is not None:
            self._callback(result)

        if result.collapsed and self._on_collapse_event is not None:
            # O(window_size). self._window is only maintained by the
            # pure-Python path, but self._recent is maintained by both, so the
            # window no longer has to be sliced off self.trace -- whose getter
            # copies the ENTIRE unbounded trace, making every collapse event
            # cost O(total stream length).
            window = list(self._recent)
            window.append(result.entropy)
            if 0 < self._window_size < len(window):
                del window[: len(window) - self._window_size]
            self._on_collapse_event(
                CollapseEvent(
                    token_index=result.token_index,
                    entropy=result.entropy,
                    delta_h=result.delta,
                    collapse_score=(
                        abs(result.delta / self._threshold) if abs(self._threshold) > 1e-15 else 0.0
                    ),
                    window=window,
                )
            )

    def _on_cpp_event(self, r: object) -> None:
        """Bridge one C++ event into the Python callbacks.

        The C++ detector fires this from *inside* add_logits/add_probs/
        add_logprobs, before those methods return and can assign
        self._last_result. Assigning it here, ahead of _emit, is what keeps the
        convenience properties (is_collapsed, collapse_score, current_entropy,
        delta_h) describing the token that triggered the callback: the
        pure-Python _push assigns _last_result before it calls _emit, and the
        two backends must not disagree inside a user callback.
        """
        result = self._wrap_cpp_result(r)
        self._last_result = result
        self._emit(result)

    def _record_cpp(self, r: object) -> CollapseResult:
        """Record the result of one C++ add_*() call and return it.

        Runs after any callback for this token has already fired, so appending
        to _recent here preserves its "window excluding the current token"
        invariant.
        """
        result = self._wrap_cpp_result(r)
        self._last_result = result
        self._recent.append(result.entropy)
        # Counted here, not in _emit: in observe-only mode the C++ core never
        # calls back, so _emit never runs on this path. _record_cpp runs once
        # per token on the C++ path exactly as _push does on the Python one,
        # which is what keeps the two counters comparable.
        self._count_if_suppressed(result)
        return result

    def _count_if_suppressed(self, result: CollapseResult) -> None:
        """Tally an event that observe-only mode withheld from the callbacks."""
        if self._observe_only and (result.collapsed or result.expanded or result.oscillating):
            self._suppressed_events += 1

    @staticmethod
    def _wrap_cpp_result(r: object) -> CollapseResult:
        """Wrap a C++ CollapseResult into our Python dataclass."""
        event = "none"
        if getattr(r, "oscillating", False):
            event = "oscillation"
        elif getattr(r, "expanded", False):
            event = "expansion"
        elif getattr(r, "collapsed", False):
            event = "collapse"

        return CollapseResult(
            entropy=getattr(r, "entropy", 0.0),
            window_mean=getattr(r, "window_mean", 0.0),
            window_std=getattr(r, "window_std", 0.0),
            delta=getattr(r, "delta", 0.0),
            z_score=getattr(r, "z_score", 0.0),
            collapsed=getattr(r, "collapsed", False),
            expanded=getattr(r, "expanded", False),
            oscillating=getattr(r, "oscillating", False),
            event=event,
            token_index=getattr(r, "token_index", 0),
        )

    def _run_clustering(self) -> None:
        """Run FastOPTICS on active matrix rows to extract super-cluster."""
        if not self._active_types or len(self._active_types) < 5:
            return

        try:
            if self._backend == "cpp":
                from shannon._core import ShannonEnergyMatrix

                matrix = ShannonEnergyMatrix.instance()
                vectors = np.array(
                    [[matrix.energy(t, j) for j in range(256)] for t in self._active_types],
                    dtype=np.float32,
                )
            else:
                import warnings

                warnings.warn(
                    "ShannonEnergyMatrix C++ core not available — "
                    "clustering requires compiled backend. Skipping.",
                    RuntimeWarning,
                    stacklevel=2,
                )
                return

            clusters = self._clusterer.cluster(vectors)
            if clusters:
                self._last_super_cluster = clusters[0]
        except Exception:
            pass  # Clustering is best-effort
