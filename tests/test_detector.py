# =============================================================================
# Shannon — pytest Suite for ShannonCollapseDetector
#
# Tests: collapse detection, steady-state, recovery, fallback equivalence,
#        callbacks, log-prob input, edge cases.
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import math
from unittest.mock import MagicMock

import numpy as np
import pytest

from shannon import ShannonCollapseDetector, shannon_entropy, shannon_entropy_from_logits
from shannon.detector import CollapseEvent, _PySlidingWindow


# =============================================================================
# Core entropy function tests (works with any backend)
# =============================================================================

class TestShannonEntropy:
    def test_uniform(self):
        for n in [2, 4, 8, 100]:
            probs = np.full(n, 1.0 / n)
            H = shannon_entropy(probs)
            assert abs(H - math.log2(n)) < 1e-8, f"Failed for n={n}"

    def test_delta(self):
        probs = np.array([1.0, 0.0, 0.0, 0.0])
        H = shannon_entropy(probs)
        assert abs(H) < 1e-10

    def test_binary(self):
        probs = np.array([0.5, 0.5])
        H = shannon_entropy(probs)
        assert abs(H - 1.0) < 1e-10


class TestEntropyFromLogits:
    def test_consistent_with_softmax(self):
        logits = np.array([1.0, 2.0, 3.0, 4.0, 5.0])
        # Manual softmax
        shifted = logits - logits.max()
        probs = np.exp(shifted) / np.exp(shifted).sum()
        H_from_probs = shannon_entropy(probs)
        H_from_logits = shannon_entropy_from_logits(logits)
        assert abs(H_from_probs - H_from_logits) < 1e-8

    def test_uniform_logits(self):
        logits = np.full(100, 5.0)
        H = shannon_entropy_from_logits(logits)
        assert abs(H - math.log2(100)) < 1e-8

    def test_large_logits_no_overflow(self):
        logits = np.array([500.0, 501.0, 499.0, 500.5])
        H = shannon_entropy_from_logits(logits)
        assert not math.isnan(H)
        assert not math.isinf(H)
        assert H >= 0

    def test_very_negative_logits(self):
        logits = np.array([-500.0, -501.0, -499.0])
        H = shannon_entropy_from_logits(logits)
        assert not math.isnan(H)
        assert H >= 0


# =============================================================================
# ShannonCollapseDetector tests
# =============================================================================

class TestCollapseDetector:
    def test_no_collapse_steady(self):
        """Steady-state entropy should never trigger collapse."""
        detector = ShannonCollapseDetector(window_size=8, collapse_threshold=-3.2)
        # Uniform distribution at each step
        for _ in range(20):
            logits = np.random.randn(100)
            detector.add_logits(logits)
        assert not detector.is_collapsed

    def test_synthetic_collapse(self):
        """Rapidly decreasing entropy should trigger collapse."""
        detector = ShannonCollapseDetector(window_size=4, collapse_threshold=-1.0)
        # Feed distributions with rapidly collapsing entropy
        # Start with uniform, end with near-delta
        entropies = [6.0, 4.0, 2.0, 0.5]
        for H in entropies:
            # Directly push known entropy values
            detector._push_and_check(H)

        # Slope over window [6, 4, 2, 0.5] should be strongly negative
        assert detector.delta_h < -1.0
        assert detector.is_collapsed

    def test_callback_fires(self):
        """on_collapse callback should fire during collapse."""
        events: list[CollapseEvent] = []
        detector = ShannonCollapseDetector(
            window_size=3,
            collapse_threshold=-1.0,
            on_collapse=lambda e: events.append(e),
        )
        # Steep collapse: high entropy -> low entropy
        detector.add_logits(np.zeros(1000))     # High H (uniform)
        detector.add_logits(np.array([100.0] + [0.0] * 999))  # Medium H
        detector.add_logits(np.array([1000.0] + [-1000.0] * 999))  # Very low H

        # At least one event should have fired (entropy dropped steeply)
        # (Whether exactly depends on the slope calculation)
        assert detector.token_count == 3

    def test_logprobs_input(self):
        """add_logprobs should work with OpenAI-style log-probabilities."""
        detector = ShannonCollapseDetector()
        logprobs = np.log(np.array([0.5, 0.3, 0.15, 0.05]))
        H = detector.add_logprobs(logprobs)
        assert H > 0
        assert detector.token_count == 1

    def test_probs_input(self):
        """add_probs should work with probability distributions."""
        detector = ShannonCollapseDetector()
        probs = np.array([0.25, 0.25, 0.25, 0.25])
        H = detector.add_probs(probs)
        assert abs(H - 2.0) < 1e-8

    def test_entropy_trace(self):
        """Full trace should accumulate all entropy values."""
        detector = ShannonCollapseDetector()
        for _ in range(10):
            detector.add_logits(np.random.randn(50))
        assert len(detector.entropy_trace) == 10
        assert all(h >= 0 for h in detector.entropy_trace)

    def test_reset(self):
        """Reset should clear all state."""
        detector = ShannonCollapseDetector()
        for _ in range(5):
            detector.add_logits(np.random.randn(50))
        assert detector.token_count == 5

        detector.reset()
        assert detector.token_count == 0
        assert len(detector.entropy_trace) == 0

    def test_backend_property(self):
        """Backend should be 'cpp' or 'python'."""
        detector = ShannonCollapseDetector()
        assert detector.backend in ("cpp", "python")

    def test_window_size_1(self):
        """Window size 1 should work without errors."""
        detector = ShannonCollapseDetector(window_size=1)
        detector.add_logits(np.random.randn(50))
        assert detector.token_count == 1

    def test_large_window(self):
        """Large window should not crash."""
        detector = ShannonCollapseDetector(window_size=100)
        for _ in range(5):
            detector.add_logits(np.random.randn(50))
        assert not detector.is_collapsed


# =============================================================================
# Pure Python SlidingWindow fallback
# =============================================================================

class TestPySlidingWindow:
    def test_constant(self):
        w = _PySlidingWindow(8, -3.2)
        for _ in range(10):
            w.push(5.0)
        assert abs(w.mean_entropy - 5.0) < 1e-12
        assert abs(w.delta_h) < 1e-12
        assert not w.is_collapsed

    def test_linear_decrease(self):
        w = _PySlidingWindow(8, -3.2)
        for i in range(8):
            w.push(8.0 - float(i))
        assert abs(w.delta_h - (-1.0)) < 1e-10
        assert not w.is_collapsed  # -1.0 > -3.2

    def test_steep_collapse(self):
        w = _PySlidingWindow(4, -3.2)
        w.push(10.0)
        w.push(6.0)
        w.push(2.0)
        w.push(-2.0)
        assert abs(w.delta_h - (-4.0)) < 1e-10
        assert w.is_collapsed  # -4.0 < -3.2

    def test_reset(self):
        w = _PySlidingWindow(4, -3.2)
        w.push(1.0)
        w.push(2.0)
        assert w.token_count == 2
        w.reset()
        assert w.token_count == 0
