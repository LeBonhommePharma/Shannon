# =============================================================================
# Shannon — Pure Python/Numba Fallback Entropy Kernels
#
# Used when C++ _core module is not available. Two fallback tiers:
#   1. Numba JIT-compiled (if numba installed) — near-C++ performance
#   2. Pure NumPy — always available
#
# Follows FlexAIDdS _HAS_CORE graceful degradation pattern.
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import numpy as np

# =============================================================================
# Tier 2: Pure NumPy fallback (always available)
# =============================================================================


def _shannon_entropy_numpy(probs: np.ndarray) -> float:
    """H = -sum(p_i * log2(p_i)), convention 0*log(0) = 0."""
    p = np.asarray(probs, dtype=np.float64)
    mask = p > 0.0
    p_pos = p[mask]
    if p_pos.size == 0:
        return 0.0
    return -float(np.sum(p_pos * np.log2(p_pos)))


def _shannon_entropy_from_logits_numpy(logits: np.ndarray) -> float:
    """Fused log-sum-exp softmax + entropy. No intermediate prob vector.

    Ported from FlexAIDdS StatMechEngine log-sum-exp:
        log_Z = max + log(sum(exp(x_i - max)))
        H = log2(e) * (log_Z - sum(x_i * exp(x_i - max)) / sum(exp(x_i - max)))
    """
    x = np.asarray(logits, dtype=np.float64)
    if x.size == 0:
        return 0.0
    if x.size == 1:
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


# =============================================================================
# Tier 1: Numba JIT-compiled (if available)
# =============================================================================

_HAS_NUMBA = False

try:
    import numba

    @numba.jit(nopython=True, cache=True, fastmath=True)
    def _shannon_entropy_numba(probs: np.ndarray) -> float:  # type: ignore[misc]
        H = 0.0
        for i in range(len(probs)):
            p = probs[i]
            if p > 0.0:
                H -= p * np.log2(p)
        return H

    @numba.jit(nopython=True, cache=True, fastmath=True)
    def _shannon_entropy_from_logits_numba(logits: np.ndarray) -> float:  # type: ignore[misc]
        n = len(logits)
        if n == 0:
            return 0.0
        if n == 1:
            return 0.0

        # Step 1: max for stability
        max_x = logits[0]
        for i in range(1, n):
            if logits[i] > max_x:
                max_x = logits[i]

        # Step 2: fused exp sums
        sum_exp = 0.0
        sum_x_exp = 0.0
        for i in range(n):
            shifted = logits[i] - max_x
            e = np.exp(shifted)
            sum_exp += e
            sum_x_exp += logits[i] * e

        # Step 3: entropy
        log_Z = max_x + np.log(sum_exp)
        mean_x = sum_x_exp / sum_exp
        LOG2_E = 1.4426950408889634  # log2(e)
        H = LOG2_E * (log_Z - mean_x)
        return max(H, 0.0)

    _HAS_NUMBA = True

except ImportError:
    pass

# =============================================================================
# Public API: select best available backend
# =============================================================================

if _HAS_NUMBA:
    shannon_entropy = _shannon_entropy_numba
    shannon_entropy_from_logits = _shannon_entropy_from_logits_numba
    _BACKEND = "numba"
else:
    shannon_entropy = _shannon_entropy_numpy
    shannon_entropy_from_logits = _shannon_entropy_from_logits_numpy
    _BACKEND = "numpy"


def get_fallback_backend() -> str:
    """Return which fallback backend is active: 'numba' or 'numpy'."""
    return _BACKEND
