# =============================================================================
# ShannonCollapseDetector — Main Python API for LLM Entropy Monitoring
#
# White-box physicochemical referee for LLM safeguarding.
# Detects "entropy collapse" — when an LLM's token distribution locks
# into a single dominant state (analogous to configurational entropy
# collapse in molecular docking).
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import dataclasses
from collections import deque
from typing import Callable

import numpy as np

# Backend selection: C++ accelerated or Numba/NumPy fallback
# Follows FlexAIDdS _HAS_CORE pattern
_HAS_CORE = False
try:
    from shannon._core import (
        SlidingWindowEntropy as _CppSlidingWindow,
        shannon_entropy as _cpp_entropy,
        shannon_entropy_from_logits as _cpp_entropy_logits,
    )
    _HAS_CORE = True
except ImportError:
    from shannon._numba_fallback import (
        shannon_entropy as _fb_entropy,
        shannon_entropy_from_logits as _fb_entropy_logits,
    )


@dataclasses.dataclass(frozen=True, slots=True)
class CollapseEvent:
    """Fired when entropy collapse is detected."""
    token_index: int
    entropy: float
    delta_h: float
    collapse_score: float
    window: list[float]


class _PySlidingWindow:
    """Pure-Python sliding window entropy tracker (fallback)."""

    def __init__(self, window_size: int = 8, collapse_threshold: float = -3.2):
        self._window_size = window_size
        self._threshold = collapse_threshold
        self._buffer: deque[float] = deque(maxlen=window_size)
        self._trace: list[float] = []

    def push(self, entropy_value: float) -> None:
        self._trace.append(entropy_value)
        self._buffer.append(entropy_value)

    @property
    def current_entropy(self) -> float:
        return self._buffer[-1] if self._buffer else 0.0

    @property
    def mean_entropy(self) -> float:
        if not self._buffer:
            return 0.0
        return sum(self._buffer) / len(self._buffer)

    @property
    def delta_h(self) -> float:
        """Linear regression slope over the window (bits/token)."""
        n = len(self._buffer)
        if n < 2:
            return 0.0
        # Closed-form slope: (n*sum(i*h_i) - sum(i)*sum(h_i)) / (n*sum(i^2) - (sum(i))^2)
        sum_i = 0.0
        sum_h = 0.0
        sum_ih = 0.0
        sum_i2 = 0.0
        for i, h in enumerate(self._buffer):
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
    def is_collapsed(self) -> bool:
        return self.delta_h < self._threshold

    @property
    def collapse_score(self) -> float:
        if abs(self._threshold) < 1e-15:
            return 0.0
        return abs(self.delta_h / self._threshold)

    @property
    def entropy_trace(self) -> list[float]:
        return list(self._trace)

    @property
    def window(self) -> list[float]:
        return list(self._buffer)

    @property
    def token_count(self) -> int:
        return len(self._trace)

    def reset(self) -> None:
        self._buffer.clear()
        self._trace.clear()


class ShannonCollapseDetector:
    """Real-time Shannon entropy collapse detector for LLM token streams.

    A white-box, 256x256-parameter physicochemical referee for LLM safeguarding.
    Monitors the entropy of token probability distributions and detects sudden
    collapse — the information-theoretic analogue of configurational entropy
    collapse in molecular docking.

    Parameters
    ----------
    window_size : int
        Number of recent entropy values to track (default: 8).
    collapse_threshold : float
        Delta-H threshold in bits/token for collapse detection (default: -3.2).
        Negative because collapse means entropy is decreasing.
    on_collapse : callable, optional
        Callback fired on collapse detection, receives a CollapseEvent.

    Examples
    --------
    >>> detector = ShannonCollapseDetector()
    >>> for logits in model_output_stream:
    ...     detector.add_logits(logits)
    ...     if detector.is_collapsed:
    ...         print(f"Collapse at token {detector.token_count}!")
    """

    def __init__(
        self,
        window_size: int = 8,
        collapse_threshold: float = -3.2,
        on_collapse: Callable[[CollapseEvent], None] | None = None,
    ):
        self._window_size = window_size
        self._collapse_threshold = collapse_threshold
        self._on_collapse = on_collapse
        self._trace: list[float] = []

        # Select backend
        if _HAS_CORE:
            self._window = _CppSlidingWindow(window_size, collapse_threshold)
            self._entropy_fn = _cpp_entropy
            self._entropy_logits_fn = _cpp_entropy_logits
            self._backend = "cpp"
        else:
            self._window = _PySlidingWindow(window_size, collapse_threshold)
            self._entropy_fn = _fb_entropy
            self._entropy_logits_fn = _fb_entropy_logits
            self._backend = "python"

    def _push_and_check(self, entropy: float) -> None:
        """Push entropy value and fire callback if collapsed."""
        self._trace.append(entropy)

        if _HAS_CORE:
            self._window.push(entropy)
            collapsed = self._window.is_collapsed()
            delta = self._window.delta_h()
            score = self._window.collapse_score()
        else:
            self._window.push(entropy)
            collapsed = self._window.is_collapsed
            delta = self._window.delta_h
            score = self._window.collapse_score

        if collapsed and self._on_collapse is not None:
            event = CollapseEvent(
                token_index=len(self._trace) - 1,
                entropy=entropy,
                delta_h=delta,
                collapse_score=score,
                window=list(self._window.window) if not _HAS_CORE
                       else list(self._window.window()),
            )
            self._on_collapse(event)

    def add_logits(self, logits: np.ndarray) -> float:
        """Compute entropy from raw logits and push to detector.

        Uses fused log-sum-exp for numerical stability.
        Returns the computed entropy in bits.
        """
        logits = np.asarray(logits, dtype=np.float64).ravel()
        H = float(self._entropy_logits_fn(logits))
        self._push_and_check(H)
        return H

    def add_probs(self, probs: np.ndarray) -> float:
        """Compute entropy from probability distribution and push.

        Returns the computed entropy in bits.
        """
        probs = np.asarray(probs, dtype=np.float64).ravel()
        H = float(self._entropy_fn(probs))
        self._push_and_check(H)
        return H

    def add_logprobs(self, logprobs: np.ndarray) -> float:
        """Compute entropy from log-probabilities (e.g., OpenAI API output).

        Converts log-probs to probs via exp(), then computes entropy.
        Returns the computed entropy in bits.
        """
        logprobs = np.asarray(logprobs, dtype=np.float64).ravel()
        probs = np.exp(logprobs)
        return self.add_probs(probs)

    @property
    def entropy_trace(self) -> list[float]:
        """Full history of entropy values (all tokens, not just window)."""
        return list(self._trace)

    @property
    def is_collapsed(self) -> bool:
        """Whether the current window indicates entropy collapse."""
        if _HAS_CORE:
            return bool(self._window.is_collapsed())
        return bool(self._window.is_collapsed)

    @property
    def collapse_score(self) -> float:
        """|delta_h / threshold|, >1.0 means collapsed."""
        if _HAS_CORE:
            return float(self._window.collapse_score())
        return float(self._window.collapse_score)

    @property
    def current_entropy(self) -> float:
        """Most recent entropy value."""
        if _HAS_CORE:
            return float(self._window.current_entropy())
        return float(self._window.current_entropy)

    @property
    def delta_h(self) -> float:
        """Rate of entropy change (bits/token), via linear regression."""
        if _HAS_CORE:
            return float(self._window.delta_h())
        return float(self._window.delta_h)

    @property
    def token_count(self) -> int:
        """Total number of tokens processed."""
        return len(self._trace)

    @property
    def backend(self) -> str:
        """Active computation backend: 'cpp' or 'python'."""
        return self._backend

    def reset(self) -> None:
        """Clear all state and start fresh."""
        self._trace.clear()
        self._window.reset()
