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
#   - O(1) running-sum window statistics
#   - FastOPTICS super-clustering on collapse (optional)
#   - C++ acceleration with Python fallback
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import dataclasses
import math
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
        self._callback = callback or on_collapse
        self._on_collapse_event = on_collapse  # Separate CollapseEvent callback

        self._window_size = window_size
        self._threshold = threshold
        self._expansion_threshold = expansion_threshold
        self._oscillation_window = oscillation_window
        self._enable_clustering = enable_clustering

        self._trace: list[float] = []
        self._window: deque[float] = deque(maxlen=window_size)
        self._event_history: deque[str] = deque(maxlen=oscillation_window)
        self._running_sum = 0.0
        self._running_sum_sq = 0.0
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
            if self._callback:
                # Wrap so Python callbacks receive the Python CollapseResult
                # dataclass, not the raw C++ binding object.
                self._cpp_detector.set_callback(
                    lambda r: self._callback(self._wrap_cpp_result(r))
                )
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
        self._event_history.clear()
        self._token_count = 0
        self._running_sum = 0.0
        self._running_sum_sq = 0.0
        self._last_super_cluster = None
        self._active_types.clear()
        self._last_result = None

    def add_logits(self, logits: ArrayLike) -> CollapseResult:
        """Feed raw logits for the current token.

        Returns CollapseResult with full event classification.
        """
        arr = _ensure_float64_1d(logits)
        if self._cpp_detector is not None:
            r = self._cpp_detector.add_logits(arr)
            self._last_result = self._wrap_cpp_result(r)
            return self._last_result
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
        arr = _ensure_float64_1d(probs)
        if self._cpp_detector is not None:
            r = self._cpp_detector.add_probs(arr)
            self._last_result = self._wrap_cpp_result(r)
            return self._last_result
        h = _entropy_from_probs(arr)
        return self._push(h)

    def add_logprobs(self, logprobs: ArrayLike) -> CollapseResult:
        """Feed log-probabilities (base e)."""
        arr = _ensure_float64_1d(logprobs)
        if self._cpp_detector is not None:
            r = self._cpp_detector.add_logprobs(arr)
            self._last_result = self._wrap_cpp_result(r)
            return self._last_result
        h = _entropy_from_logprobs(arr)
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
    def super_cluster(self) -> SuperClusterInfo | None:
        """Most recent super-cluster from FastOPTICS (None if not triggered)."""
        return self._last_super_cluster

    def _push(self, h: float) -> CollapseResult:
        """Push an entropy value through the Python fallback detector."""
        self._trace.append(h)

        # O(1) running-sum window statistics
        if len(self._window) == self._window.maxlen:
            outgoing = self._window[0]
            self._running_sum -= outgoing
            self._running_sum_sq -= outgoing * outgoing

        self._window.append(h)
        self._running_sum += h
        self._running_sum_sq += h * h

        count = len(self._window)
        mean = self._running_sum / count if count > 0 else 0.0

        if count > 1:
            variance = (self._running_sum_sq / count) - (mean * mean)
            std = math.sqrt(max(0.0, variance))
        else:
            std = 0.0

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
            if alternations >= 2:
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

        if (collapsed or expanded or oscillating) and self._callback:
            self._callback(result)

        # Fire CollapseEvent for legacy on_collapse callback
        if collapsed and self._on_collapse_event is not None:
            evt = CollapseEvent(
                token_index=result.token_index,
                entropy=h,
                delta_h=delta,
                collapse_score=abs(delta / self._threshold) if abs(self._threshold) > 1e-15 else 0.0,
                window=list(self._window),
            )
            self._on_collapse_event(evt)

        # Trigger super-clustering on collapse
        if collapsed and self._enable_clustering:
            self._run_clustering()

        return result

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

    @property
    def _current_mean(self) -> float:
        return self._running_sum / max(1, len(self._window))
