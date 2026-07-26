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

import warnings

__version__ = "2.1.0"

# Backend selection: C++ accelerated or Python fallback
# Follows FlexAIDdS _HAS_CORE graceful degradation pattern
_HAS_CORE = False
_CORE_EXPORTS: dict[str, object] = {}

try:
    from shannon._core import (  # noqa: F401
        compute_entropy,
        compute_entropy_from_logits,
        EntropyResult,
        SlidingWindowEntropy as _SlidingWindowEntropy,
        ShannonEnergyMatrix,
        HardwareInfo,
        get_hardware_info,
    )
    _HAS_CORE = True
    _CORE_EXPORTS = {
        "compute_entropy": compute_entropy,
        "compute_entropy_from_logits": compute_entropy_from_logits,
        "EntropyResult": EntropyResult,
        "ShannonEnergyMatrix": ShannonEnergyMatrix,
        "HardwareInfo": HardwareInfo,
        "get_hardware_info": get_hardware_info,
        # SlidingWindowEntropy is lazy via __getattr__ (deprecated).
        "_SlidingWindowEntropy": _SlidingWindowEntropy,
    }
except ImportError:
    pass

# The entropy kernels are always exported from the dispatch layer, never bound
# straight off shannon._core. The dispatch wrappers coerce array-likes (lists,
# tuples) to float64 1-D arrays before calling into C++; the raw pybind11
# signatures accept numpy.ndarray only, so re-exporting them directly would
# make the public API reject plain lists whenever the C++ core is present.
from shannon._numba_fallback import (
    _ensure_float64_1d,
    shannon_entropy,
    shannon_entropy_from_logits,
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

# Re-export non-deprecated C++ symbols when available.
if _HAS_CORE:
    compute_entropy = _CORE_EXPORTS["compute_entropy"]
    compute_entropy_from_logits = _CORE_EXPORTS["compute_entropy_from_logits"]
    EntropyResult = _CORE_EXPORTS["EntropyResult"]
    ShannonEnergyMatrix = _CORE_EXPORTS["ShannonEnergyMatrix"]
    HardwareInfo = _CORE_EXPORTS["HardwareInfo"]
    get_hardware_info = _CORE_EXPORTS["get_hardware_info"]
    __all__.extend([
        "compute_entropy",
        "compute_entropy_from_logits",
        "EntropyResult",
        "SlidingWindowEntropy",  # deprecated — see __getattr__
        "ShannonEnergyMatrix",
        "HardwareInfo",
        "get_hardware_info",
    ])


def __getattr__(name: str):
    """Lazy deprecated exports (SlidingWindowEntropy)."""
    if name == "SlidingWindowEntropy":
        if not _HAS_CORE:
            raise AttributeError(
                "SlidingWindowEntropy requires the C++ extension (shannon._core)"
            )
        warnings.warn(
            "SlidingWindowEntropy is deprecated; use ShannonCollapseDetector "
            "(canonical detector API). SlidingWindowEntropy will be removed "
            "from the public surface in a future release.",
            DeprecationWarning,
            stacklevel=2,
        )
        return _CORE_EXPORTS["_SlidingWindowEntropy"]
    raise AttributeError(f"module 'shannon' has no attribute {name!r}")
