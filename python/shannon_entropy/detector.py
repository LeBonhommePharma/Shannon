# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
ShannonCollapseDetector — streaming entropy collapse detection for LLM outputs.

This is the main user-facing class. It wraps the C++ CollapseDetector when
available, falling back to a pure-Python implementation otherwise.
"""

from __future__ import annotations

import dataclasses
import math
from collections import deque
from collections.abc import Callable

import numpy as np
from numpy.typing import ArrayLike

from shannon_entropy.core import (
    _ensure_float64_1d,
    shannon_configurational_entropy,
    shannon_entropy_from_logprobs,
    shannon_entropy_from_probs,
)

DEFAULT_WINDOW_SIZE = 8
DEFAULT_COLLAPSE_THRESHOLD = -3.2  # bits
DEFAULT_EXPANSION_THRESHOLD = +3.2  # bits
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


class ShannonCollapseDetector:
    """Streaming Shannon entropy collapse detector for LLM token distributions.

    Maintains a sliding window of entropy values and detects sudden drops
    ("collapses") that signal evaluation awareness or strategic deception
    in frontier LLM agents.

    Parameters
    ----------
    window_size : int
        Number of past entropy values to maintain in the sliding window.
    threshold : float
        Collapse threshold in bits. A token is flagged when its entropy
        drops more than this amount below the window mean.
    callback : callable, optional
        Function called on every collapse event with a CollapseResult.

    Examples
    --------
    >>> detector = ShannonCollapseDetector()
    >>> result = detector.add_logits(np.random.randn(50000))
    >>> print(f"Entropy: {result.entropy:.2f} bits")
    """

    def __init__(
        self,
        window_size: int = DEFAULT_WINDOW_SIZE,
        threshold: float = DEFAULT_COLLAPSE_THRESHOLD,
        expansion_threshold: float = DEFAULT_EXPANSION_THRESHOLD,
        oscillation_window: int = DEFAULT_OSCILLATION_WINDOW,
        callback: CollapseCallback | None = None,
    ) -> None:
        self._cpp_detector = None
        try:
            from _shannon_cpp import CollapseDetector as CppDetector

            self._cpp_detector = CppDetector(
                window_size, threshold, expansion_threshold, oscillation_window
            )
            if callback:
                self._cpp_detector.set_callback(callback)
        except ImportError:
            pass

        self._window_size = window_size
        self._threshold = threshold
        self._expansion_threshold = expansion_threshold
        self._oscillation_window = oscillation_window
        self._callback = callback

        self._trace: list[float] = []
        self._window: deque[float] = deque(maxlen=window_size)
        self._event_history: deque[str] = deque(maxlen=oscillation_window)
        self._token_count = 0
        self._running_sum = 0.0
        self._running_sum_sq = 0.0

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

    def add_logits(self, logits: ArrayLike) -> CollapseResult:
        """Feed raw logits for the current token.

        Parameters
        ----------
        logits : array-like
            Unnormalized log-weights from the model's output layer.

        Returns
        -------
        CollapseResult
        """
        arr = _ensure_float64_1d(logits)
        if self._cpp_detector is not None:
            r = self._cpp_detector.add_logits(arr)
            return self._wrap_cpp_result(r)
        h = shannon_configurational_entropy(arr)
        return self._push(h)

    def add_probs(self, probs: ArrayLike) -> CollapseResult:
        """Feed a normalized probability distribution.

        Parameters
        ----------
        probs : array-like
            Token probability distribution (should sum to ~1).

        Returns
        -------
        CollapseResult
        """
        arr = _ensure_float64_1d(probs)
        if self._cpp_detector is not None:
            r = self._cpp_detector.add_probs(arr)
            return self._wrap_cpp_result(r)
        h = shannon_entropy_from_probs(arr)
        return self._push(h)

    def add_logprobs(self, logprobs: ArrayLike) -> CollapseResult:
        """Feed log-probabilities (base e).

        Parameters
        ----------
        logprobs : array-like
            Log-probabilities from the model.

        Returns
        -------
        CollapseResult
        """
        arr = _ensure_float64_1d(logprobs)
        if self._cpp_detector is not None:
            r = self._cpp_detector.add_logprobs(arr)
            return self._wrap_cpp_result(r)
        h = shannon_entropy_from_logprobs(arr)
        return self._push(h)

    @property
    def trace(self) -> list[float]:
        """Full entropy trace (all tokens seen so far)."""
        if self._cpp_detector is not None:
            return list(self._cpp_detector.trace)
        return list(self._trace)

    @property
    def window_size(self) -> int:
        return self._window_size

    @property
    def threshold(self) -> float:
        return self._threshold

    def _push(self, h: float) -> CollapseResult:
        """Push an entropy value through the Python fallback detector."""
        self._trace.append(h)

        # Subtract outgoing value before deque auto-evicts it
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
        self._token_count += 1

        if (collapsed or expanded or oscillating) and self._callback:
            self._callback(result)

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
