# =============================================================================
# Shannon — Pure Python/Numba/C++ Fallback Entropy Kernels
#
# Three-tier backend:
#   1. C++ _core module (if compiled) — SIMD+OpenMP accelerated
#   2. Numba JIT-compiled (if numba installed) — near-C++ performance
#   3. Pure NumPy — always available
#
# Follows FlexAIDdS _HAS_CORE graceful degradation pattern.
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import numpy as np
from numpy.typing import ArrayLike

# ── Tier 0: C++ accelerated backend ──────────────────────────────────────────

_USE_CPP = False

try:
    from shannon._core import (
        shannon_entropy as _cpp_entropy,
        shannon_entropy_from_logits as _cpp_entropy_logits,
    )
    _USE_CPP = True
except ImportError:
    pass

# ── Helpers ──────────────────────────────────────────────────────────────────


def _ensure_float64_1d(x: ArrayLike) -> np.ndarray:
    """Convert to float64 1-D C-contiguous array, avoiding copy if already suitable."""
    if isinstance(x, np.ndarray) and x.dtype == np.float64 and x.ndim == 1 and x.flags['C_CONTIGUOUS']:
        return x
    return np.asarray(x, dtype=np.float64).ravel()


# ── Tier 2: Pure NumPy fallback (always available) ───────────────────────────


def _numpy_from_probs(probs: np.ndarray) -> float:
    """H = -sum(p_i * log2(p_i)), convention 0*log(0) = 0."""
    mask = probs > 1e-300
    if not np.any(mask):
        return 0.0
    h = -np.sum(probs[mask] * np.log2(probs[mask]))
    return float(max(0.0, h))


def _numpy_from_logits(logits: np.ndarray) -> float:
    """Fused log-sum-exp softmax + entropy. No intermediate prob vector.

    Ported from FlexAIDdS StatMechEngine log-sum-exp:
        log_Z = max + log(sum(exp(x_i - max)))
        H = log2(e) * (log_Z - sum(x_i * exp(x_i - max)) / sum(exp(x_i - max)))
    """
    x = np.asarray(logits, dtype=np.float64)
    if x.size <= 1:
        return 0.0

    max_x = np.max(x)
    shifted = x - max_x
    exp_shifted = np.exp(shifted)
    sum_exp = np.sum(exp_shifted)
    sum_x_exp = np.sum(x * exp_shifted)

    log_Z = max_x + np.log(sum_exp)
    mean_x = sum_x_exp / sum_exp
    H = np.log2(np.e) * (log_Z - mean_x)
    return max(float(H), 0.0)


def _numpy_configurational_entropy(log_weights: np.ndarray) -> float:
    """Log-sum-exp Shannon configurational entropy from unnormalized log-weights."""
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


def _numpy_from_logprobs(logprobs: np.ndarray) -> float:
    """Compute entropy from log-probabilities (base e)."""
    LOG2E = 1.44269504088896340736
    p = np.exp(logprobs)
    mask = p > 1e-300
    if not np.any(mask):
        return 0.0
    h = -np.sum(p[mask] * logprobs[mask] * LOG2E)
    return float(max(0.0, h))


# ── Tier 1: Numba JIT-compiled (if available) ────────────────────────────────

_USE_NUMBA = False

if not _USE_CPP:
    try:
        import numba
        from numba import njit, prange  # type: ignore[import-untyped]

        @njit(cache=True, fastmath=True)  # type: ignore[misc]
        def _numba_from_probs_numba(probs: np.ndarray) -> float:
            n = probs.shape[0]
            if n == 0:
                return 0.0
            h = 0.0
            for i in prange(n):
                if probs[i] > 1e-300:
                    h -= probs[i] * np.log2(probs[i])
            return max(0.0, h)

        @njit(cache=True, fastmath=True)  # type: ignore[misc]
        def _numba_from_logits_numba(logits: np.ndarray) -> float:
            n = len(logits)
            if n <= 1:
                return 0.0

            max_x = logits[0]
            for i in range(1, n):
                if logits[i] > max_x:
                    max_x = logits[i]

            sum_exp = 0.0
            sum_x_exp = 0.0
            for i in range(n):
                shifted = logits[i] - max_x
                e = np.exp(shifted)
                sum_exp += e
                sum_x_exp += logits[i] * e

            log_Z = max_x + np.log(sum_exp)
            mean_x = sum_x_exp / sum_exp
            LOG2_E = 1.4426950408889634
            H = LOG2_E * (log_Z - mean_x)
            return max(H, 0.0)

        @njit(cache=True, fastmath=True)  # type: ignore[misc]
        def _numba_configurational_entropy_numba(log_weights: np.ndarray) -> float:
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
        def _numba_from_logprobs_numba(logprobs: np.ndarray) -> float:
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

        _USE_NUMBA = True

    except ImportError:
        pass


# ── Public API: unified dispatch across all tiers ────────────────────────────


def shannon_entropy(probs: ArrayLike) -> float:
    """Compute Shannon entropy from a normalized probability distribution."""
    if _USE_CPP:
        return float(_cpp_entropy(_ensure_float64_1d(probs)))
    arr = _ensure_float64_1d(probs)
    if _USE_NUMBA:
        return float(_numba_from_probs_numba(arr))
    return _numpy_from_probs(arr)


def shannon_entropy_from_logits(logits: ArrayLike) -> float:
    """Compute Shannon entropy from unnormalized logits (fused log-sum-exp)."""
    if _USE_CPP:
        return float(_cpp_entropy_logits(_ensure_float64_1d(logits)))
    arr = _ensure_float64_1d(logits)
    if _USE_NUMBA:
        return float(_numba_from_logits_numba(arr))
    return _numpy_from_logits(arr)


def shannon_configurational_entropy(log_weights: ArrayLike) -> float:
    """Compute Shannon configurational entropy from unnormalized log-weights.

    Uses log-sum-exp for numerical stability. Returns entropy in bits.
    """
    arr = _ensure_float64_1d(log_weights)
    if _USE_NUMBA:
        return float(_numba_configurational_entropy_numba(arr))
    return _numpy_configurational_entropy(arr)


def shannon_entropy_from_logprobs(logprobs: ArrayLike) -> float:
    """Compute Shannon entropy from log-probabilities (base e)."""
    arr = _ensure_float64_1d(logprobs)
    if _USE_NUMBA:
        return float(_numba_from_logprobs_numba(arr))
    return _numpy_from_logprobs(arr)


def get_backend() -> str:
    """Return the active computation backend name."""
    if _USE_CPP:
        return "cpp"
    if _USE_NUMBA:
        return "numba"
    return "numpy"


# Backwards compat alias
get_fallback_backend = get_backend
