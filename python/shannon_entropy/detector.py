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
from typing import Callable, Optional, Sequence

import numpy as np
from numpy.typing import ArrayLike

from shannon_entropy.core import (
    shannon_configurational_entropy,
    shannon_entropy_from_logprobs,
    shannon_entropy_from_probs,
)

DEFAULT_WINDOW_SIZE = 8
DEFAULT_COLLAPSE_THRESHOLD = -3.2  # bits


@dataclasses.dataclass(frozen=True, slots=True)
class CollapseResult:
    """Result from a single step of collapse detection."""

    entropy: float
    """Current token entropy (bits)."""

    window_mean: float
    """Mean entropy over the sliding window."""

    window_std: float
    """Standard deviation of entropy over the window."""

    delta: float
    """entropy - window_mean (negative indicates collapse)."""

    z_score: float
    """Standardised score: delta / window_std."""

    collapsed: bool
    """True if the entropy dropped below threshold relative to window mean."""

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
        callback: Optional[CollapseCallback] = None,
    ) -> None:
        # Try to use C++ backend
        self._cpp_detector = None
        try:
            from _shannon_cpp import CollapseDetector as CppDetector
            self._cpp_detector = CppDetector(window_size, threshold)
            if callback:
                self._cpp_detector.set_callback(callback)
        except ImportError:
            pass

        self._window_size = window_size
        self._threshold = threshold
        self._callback = callback

        # Python fallback state
        self._trace: list[float] = []
        self._window: deque[float] = deque(maxlen=window_size)
        self._token_count = 0

    def reset(self) -> None:
        """Clear all internal state."""
        if self._cpp_detector is not None:
            self._cpp_detector.reset()
        self._trace.clear()
        self._window.clear()
        self._token_count = 0

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
        arr = np.asarray(logits, dtype=np.float64).ravel()
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
        arr = np.asarray(probs, dtype=np.float64).ravel()
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
        arr = np.asarray(logprobs, dtype=np.float64).ravel()
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
        self._window.append(h)

        count = len(self._window)
        mean = sum(self._window) / count if count > 0 else 0.0

        if count > 1:
            variance = sum((x - mean) ** 2 for x in self._window) / count
            std = math.sqrt(max(0.0, variance))
        else:
            std = 0.0

        delta = h - mean
        z = delta / std if std > 1e-12 else 0.0
        collapsed = (count >= self._window_size) and (delta < self._threshold)

        result = CollapseResult(
            entropy=h,
            window_mean=mean,
            window_std=std,
            delta=delta,
            z_score=z,
            collapsed=collapsed,
            token_index=self._token_count,
        )
        self._token_count += 1

        if collapsed and self._callback:
            self._callback(result)

        return result

    @staticmethod
    def _wrap_cpp_result(r: object) -> CollapseResult:
        """Wrap a C++ CollapseResult into our Python dataclass."""
        return CollapseResult(
            entropy=r.entropy,  # type: ignore[attr-defined]
            window_mean=r.window_mean,  # type: ignore[attr-defined]
            window_std=r.window_std,  # type: ignore[attr-defined]
            delta=r.delta,  # type: ignore[attr-defined]
            z_score=r.z_score,  # type: ignore[attr-defined]
            collapsed=r.collapsed,  # type: ignore[attr-defined]
            token_index=r.token_index,  # type: ignore[attr-defined]
        )
