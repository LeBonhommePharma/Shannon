# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Core entropy computation functions.

Tries to use the C++ accelerated backend (_shannon_cpp); falls back to
a pure-Numba implementation for environments without compiled extensions.
"""

from __future__ import annotations

import numpy as np
from numpy.typing import ArrayLike

# ── Backend selection ────────────────────────────────────────────────────────

_USE_CPP = False

try:
    from _shannon_cpp import (
        shannon_configurational_entropy as _cpp_conf_entropy,
        shannon_entropy_from_probs as _cpp_from_probs,
        shannon_entropy_from_logprobs as _cpp_from_logprobs,
    )
    _USE_CPP = True
except ImportError:
    pass

# ── Numba fallback ───────────────────────────────────────────────────────────

_USE_NUMBA = False

if not _USE_CPP:
    try:
        from numba import njit, prange  # type: ignore[import-untyped]
        _USE_NUMBA = True
    except ImportError:
        pass

if _USE_NUMBA:
    from numba import njit, prange  # type: ignore[import-untyped]

    @njit(cache=True, fastmath=True)  # type: ignore[misc]
    def _numba_conf_entropy(log_weights: np.ndarray) -> float:
        """Log-sum-exp Shannon configurational entropy (Numba kernel)."""
        n = log_weights.shape[0]
        if n <= 1:
            return 0.0

        max_w = log_weights[0]
        for i in range(1, n):
            if log_weights[i] > max_w:
                max_w = log_weights[i]

        Z = 0.0
        weighted_sum = 0.0
        for i in prange(n):
            shifted = log_weights[i] - max_w
            exp_val = np.exp(shifted)
            Z += exp_val
            weighted_sum += shifted * exp_val

        if Z <= 0.0:
            return 0.0

        LN2 = 0.693147180559945309417
        log2_Z = np.log2(Z)
        entropy = log2_Z - weighted_sum / (Z * LN2)
        return max(0.0, entropy)

    @njit(cache=True, fastmath=True)  # type: ignore[misc]
    def _numba_from_probs(probs: np.ndarray) -> float:
        n = probs.shape[0]
        if n == 0:
            return 0.0
        h = 0.0
        for i in prange(n):
            if probs[i] > 1e-300:
                h -= probs[i] * np.log2(probs[i])
        return max(0.0, h)

    @njit(cache=True, fastmath=True)  # type: ignore[misc]
    def _numba_from_logprobs(logprobs: np.ndarray) -> float:
        n = logprobs.shape[0]
        if n == 0:
            return 0.0
        LOG2E = 1.44269504088896340736
        h = 0.0
        for i in prange(n):
            p = np.exp(logprobs[i])
            if p > 1e-300:
                h -= p * logprobs[i] * LOG2E
        return max(0.0, h)


# ── Pure-NumPy fallback (no Numba, no C++) ───────────────────────────────────

def _numpy_conf_entropy(log_weights: np.ndarray) -> float:
    """Log-sum-exp Shannon configurational entropy (pure NumPy)."""
    if log_weights.size <= 1:
        return 0.0

    max_w = np.max(log_weights)
    shifted = log_weights - max_w
    exp_vals = np.exp(shifted)
    Z = np.sum(exp_vals)

    if Z <= 0.0:
        return 0.0

    LN2 = 0.693147180559945309417
    weighted_sum = np.sum(shifted * exp_vals)
    entropy = np.log2(Z) - weighted_sum / (Z * LN2)
    return float(max(0.0, entropy))


def _numpy_from_probs(probs: np.ndarray) -> float:
    mask = probs > 1e-300
    if not np.any(mask):
        return 0.0
    h = -np.sum(probs[mask] * np.log2(probs[mask]))
    return float(max(0.0, h))


def _numpy_from_logprobs(logprobs: np.ndarray) -> float:
    LOG2E = 1.44269504088896340736
    p = np.exp(logprobs)
    mask = p > 1e-300
    if not np.any(mask):
        return 0.0
    h = -np.sum(p[mask] * logprobs[mask] * LOG2E)
    return float(max(0.0, h))


# ── Helpers ──────────────────────────────────────────────────────────────────

def _ensure_float64_1d(x: ArrayLike) -> np.ndarray:
    """Convert to float64 1-D C-contiguous array, avoiding copy if already suitable."""
    if isinstance(x, np.ndarray) and x.dtype == np.float64 and x.ndim == 1 and x.flags['C_CONTIGUOUS']:
        return x
    return np.asarray(x, dtype=np.float64).ravel()


# ── Public API ───────────────────────────────────────────────────────────────

def shannon_configurational_entropy(log_weights: ArrayLike) -> float:
    """Compute Shannon configurational entropy from unnormalized log-weights.

    Uses log-sum-exp for numerical stability. Returns entropy in bits.

    Parameters
    ----------
    log_weights : array-like
        Unnormalized log-weights (e.g. raw logits from an LLM).

    Returns
    -------
    float
        Entropy in bits (>= 0).
    """
    arr = _ensure_float64_1d(log_weights)
    if _USE_CPP:
        return float(_cpp_conf_entropy(arr))
    if _USE_NUMBA:
        return float(_numba_conf_entropy(arr))
    return _numpy_conf_entropy(arr)


def shannon_entropy_from_probs(probs: ArrayLike) -> float:
    """Compute Shannon entropy from a normalized probability distribution.

    Parameters
    ----------
    probs : array-like
        Probability distribution (should sum to ~1).

    Returns
    -------
    float
        Entropy in bits.
    """
    arr = _ensure_float64_1d(probs)
    if _USE_CPP:
        return float(_cpp_from_probs(arr))
    if _USE_NUMBA:
        return float(_numba_from_probs(arr))
    return _numpy_from_probs(arr)


def shannon_entropy_from_logprobs(logprobs: ArrayLike) -> float:
    """Compute Shannon entropy from log-probabilities (base e).

    Parameters
    ----------
    logprobs : array-like
        Log-probabilities (base e).

    Returns
    -------
    float
        Entropy in bits.
    """
    arr = _ensure_float64_1d(logprobs)
    if _USE_CPP:
        return float(_cpp_from_logprobs(arr))
    if _USE_NUMBA:
        return float(_numba_from_logprobs(arr))
    return _numpy_from_logprobs(arr)


def get_backend() -> str:
    """Return the active computation backend name."""
    if _USE_CPP:
        return "cpp"
    if _USE_NUMBA:
        return "numba"
    return "numpy"
