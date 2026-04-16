# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""Tests for the Shannon entropy collapse detector (Python)."""

import math

import numpy as np
from shannon_entropy import (
    ShannonCollapseDetector,
    shannon_configurational_entropy,
    shannon_entropy_from_logprobs,
    shannon_entropy_from_probs,
)
from shannon_entropy.core import get_backend

# ── Core entropy functions ───────────────────────────────────────────────────


class TestConfigurationalEntropy:
    def test_empty(self):
        assert shannon_configurational_entropy([]) == 0.0

    def test_single(self):
        assert shannon_configurational_entropy([5.0]) == 0.0

    def test_uniform(self):
        # N equal → log2(N)
        N = 1024
        h = shannon_configurational_entropy(np.zeros(N))
        assert abs(h - math.log2(N)) < 1e-10

    def test_delta(self):
        h = shannon_configurational_entropy([100.0, -100.0, -100.0])
        assert h < 0.01

    def test_two_equal(self):
        h = shannon_configurational_entropy([0.0, 0.0])
        assert abs(h - 1.0) < 1e-10

    def test_numerical_stability_large(self):
        h = shannon_configurational_entropy([1000.0, 1000.0, 1000.0, 1000.0])
        assert abs(h - 2.0) < 1e-10

    def test_numerical_stability_negative(self):
        h = shannon_configurational_entropy([-1000.0, -1000.0])
        assert abs(h - 1.0) < 1e-10

    def test_large_vocabulary(self):
        rng = np.random.default_rng(42)
        logits = rng.normal(0, 3, size=50000)
        h = shannon_configurational_entropy(logits)
        assert 0 < h <= math.log2(50000)


class TestEntropyFromProbs:
    def test_uniform(self):
        h = shannon_entropy_from_probs([0.25, 0.25, 0.25, 0.25])
        assert abs(h - 2.0) < 1e-10

    def test_delta(self):
        h = shannon_entropy_from_probs([1.0, 0.0, 0.0])
        assert abs(h) < 1e-10

    def test_binary(self):
        h = shannon_entropy_from_probs([0.5, 0.5])
        assert abs(h - 1.0) < 1e-10


class TestEntropyFromLogprobs:
    def test_uniform(self):
        lp = math.log(0.25)
        h = shannon_entropy_from_logprobs([lp, lp, lp, lp])
        assert abs(h - 2.0) < 1e-10


# ── Collapse Detector ────────────────────────────────────────────────────────


class TestShannonCollapseDetector:
    def test_basic_flow(self):
        det = ShannonCollapseDetector(window_size=4, threshold=-2.0)
        uniform = np.zeros(8)  # log2(8) = 3 bits
        for _ in range(4):
            r = det.add_logits(uniform)
            assert not r.collapsed

    def test_collapse_detection(self):
        det = ShannonCollapseDetector(window_size=4, threshold=-2.0)

        # Fill window with high-entropy
        for _ in range(4):
            det.add_logits(np.zeros(1024))

        # Inject low-entropy → collapse
        spike = np.full(1024, -100.0)
        spike[0] = 100.0
        result = det.add_logits(spike)
        assert result.delta < 0

    def test_callback(self):
        events = []
        det = ShannonCollapseDetector(
            window_size=4,
            threshold=-1.0,
            callback=lambda r: events.append(r),
        )

        for _ in range(4):
            det.add_logits(np.zeros(8))

        spike = np.full(8, -100.0)
        spike[0] = 100.0
        det.add_logits(spike)

        assert len(events) >= 1

    def test_trace(self):
        det = ShannonCollapseDetector()
        rng = np.random.default_rng(99)
        for _ in range(10):
            det.add_logits(rng.standard_normal(100))
        assert len(det.trace) == 10

    def test_reset(self):
        det = ShannonCollapseDetector()
        det.add_logits(np.zeros(10))
        assert len(det.trace) == 1
        det.reset()
        assert len(det.trace) == 0

    def test_probs_interface(self):
        det = ShannonCollapseDetector()
        probs = np.array([0.25, 0.25, 0.25, 0.25])
        result = det.add_probs(probs)
        assert abs(result.entropy - 2.0) < 1e-10

    def test_logprobs_interface(self):
        det = ShannonCollapseDetector()
        logprobs = np.log(np.array([0.5, 0.5]))
        result = det.add_logprobs(logprobs)
        assert abs(result.entropy - 1.0) < 1e-10


# ── Synthetic collapse patterns ──────────────────────────────────────────────


class TestSyntheticPatterns:
    """Test with realistic synthetic patterns mimicking LLM behaviour."""

    def test_gradual_then_sudden_collapse(self):
        """Steady entropy followed by a sharp drop → collapse."""
        det = ShannonCollapseDetector(window_size=8, threshold=-3.0)

        # Steady high-entropy phase (fill window)
        for _ in range(16):
            det.add_logits(np.zeros(1000))  # log2(1000) ≈ 10 bits

        # Sudden drop: only 2 active logits → log2(2) = 1 bit
        # delta ≈ 1 - 10 = -9, well below threshold
        logits = np.full(1000, -100.0)
        logits[:2] = 0.0
        result = det.add_logits(logits)
        assert result.collapsed

    def test_sudden_spike(self):
        """Single sudden entropy drop (evaluation awareness signal)."""
        det = ShannonCollapseDetector(window_size=8, threshold=-3.0)

        # Steady high entropy
        for _ in range(16):
            det.add_logits(np.zeros(1000))

        # Sudden collapse
        spike = np.full(1000, -100.0)
        spike[0] = 100.0
        result = det.add_logits(spike)
        assert result.collapsed
        assert result.z_score < -2.0

    def test_no_false_positive_stable(self):
        """Stable entropy should not trigger false collapses."""
        det = ShannonCollapseDetector(window_size=8, threshold=-3.2)

        rng = np.random.default_rng(42)
        collapses = 0
        for _ in range(1000):
            logits = rng.normal(0, 1, size=100)
            result = det.add_logits(logits)
            if result.collapsed:
                collapses += 1

        # FP rate should be very low
        assert collapses / 1000 < 0.01


class TestBackend:
    def test_backend_available(self):
        backend = get_backend()
        assert backend in ("cpp", "numba", "numpy")
