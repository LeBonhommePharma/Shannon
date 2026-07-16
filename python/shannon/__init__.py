# =============================================================================
# Shannon — White-Box Physicochemical Referee for LLM Safeguarding
#
# A standalone library implementing Shannon entropy collapse detection —
# a physics-grounded primitive for zero-shot detection of evaluation
# awareness and strategic deception in frontier LLM agents.
#
# Ported from FlexAIDdS (lmorency/FlexAIDdS).
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

"""Shannon entropy collapse detection for LLM safety monitoring.

Usage:
    >>> from shannon import ShannonCollapseDetector
    >>> detector = ShannonCollapseDetector()
    >>> for logits in model_stream:
    ...     detector.add_logits(logits)
    ...     if detector.is_collapsed:
    ...         print("Entropy collapse detected!")
"""

from __future__ import annotations

__version__ = "2.0.0"

# Backend selection: C++ accelerated or Python fallback
# Follows FlexAIDdS _HAS_CORE graceful degradation pattern
_HAS_CORE = False

try:
    from shannon._core import (
        shannon_entropy,
        shannon_entropy_from_logits,
        compute_entropy,
        compute_entropy_from_logits,
        EntropyResult,
        SlidingWindowEntropy,
        ShannonEnergyMatrix,
        HardwareInfo,
        get_hardware_info,
    )
    _HAS_CORE = True
except ImportError:
    from shannon._numba_fallback import (
        shannon_entropy,
        shannon_entropy_from_logits,
        shannon_configurational_entropy,
        shannon_entropy_from_logprobs,
        get_backend,
    )

from shannon._numba_fallback import (
    _ensure_float64_1d,
    shannon_configurational_entropy,
    shannon_entropy_from_logprobs,
    get_backend,
)
from shannon.detector import ShannonCollapseDetector, CollapseEvent, CollapseResult

__all__ = [
    # Core functions
    "shannon_entropy",
    "shannon_entropy_from_logits",
    "shannon_configurational_entropy",
    "shannon_entropy_from_logprobs",
    "shannon_entropy_from_probs",  # alias for shannon_entropy
    # Detector
    "ShannonCollapseDetector",
    "CollapseEvent",
    "CollapseResult",
    # Backend info
    "_HAS_CORE",
    "get_backend",
    "__version__",
]

# Alias: shannon_entropy_from_probs is the same as shannon_entropy
shannon_entropy_from_probs = shannon_entropy

# Extend exports when C++ core is available
if _HAS_CORE:
    __all__.extend([
        "compute_entropy",
        "compute_entropy_from_logits",
        "EntropyResult",
        "SlidingWindowEntropy",
        "ShannonEnergyMatrix",
        "HardwareInfo",
        "get_hardware_info",
    ])
