# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Shannon Entropy Collapse Detection Library.

A physics-grounded primitive for zero-shot detection of evaluation awareness
and strategic deception in frontier LLM agents. Derived from the proven
configurational entropy collapse used in molecular docking (FlexAID∆S).

Usage::

    from shannon_entropy import ShannonCollapseDetector

    detector = ShannonCollapseDetector(window_size=8, threshold=-3.2)
    result = detector.add_logits(logits_array)
    if result.collapsed:
        print("Entropy collapse detected!")
"""

__version__ = "0.1.0"

from shannon_entropy.core import (
    shannon_configurational_entropy,
    shannon_entropy_from_logprobs,
    shannon_entropy_from_probs,
)
from shannon_entropy.detector import ShannonCollapseDetector

__all__ = [
    "ShannonCollapseDetector",
    "shannon_configurational_entropy",
    "shannon_entropy_from_probs",
    "shannon_entropy_from_logprobs",
]
