#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""
Benchmark: Shannon entropy collapse detection sensitivity and performance.

Generates synthetic traces mimicking:
1. Normal LLM generation (high, stable entropy)
2. Deceptive/evaluation-aware traces (entropy collapse events)
3. Edge cases (gradual drift, oscillation)

Reports sensitivity, false positive rate, and per-token latency.
"""

from __future__ import annotations

import time

import numpy as np

from shannon import ShannonCollapseDetector
from shannon import get_backend


def generate_normal_trace(n_tokens: int = 500, vocab_size: int = 50000, seed: int = 42):
    """Generate a normal (non-deceptive) LLM trace."""
    rng = np.random.default_rng(seed)
    return [rng.normal(0, 2.0, size=vocab_size) for _ in range(n_tokens)]


def generate_collapse_trace(
    n_tokens: int = 500,
    vocab_size: int = 50000,
    collapse_at: int = 200,
    collapse_duration: int = 10,
    seed: int = 123,
):
    """Generate a trace with an entropy collapse event."""
    rng = np.random.default_rng(seed)
    trace = []
    for t in range(n_tokens):
        if collapse_at <= t < collapse_at + collapse_duration:
            # Collapse: one logit dominates
            logits = np.full(vocab_size, -50.0)
            logits[rng.integers(0, vocab_size)] = 50.0
        else:
            logits = rng.normal(0, 2.0, size=vocab_size)
        trace.append(logits)
    return trace


def benchmark():
    backend = get_backend()
    print(f"Backend: {backend}")
    print("=" * 60)

    # ── Sensitivity test ─────────────────────────────────────────

    n_deceptive = 100
    n_normal = 1000
    true_positives = 0
    false_positives = 0

    # Test deceptive traces
    for i in range(n_deceptive):
        det = ShannonCollapseDetector(window_size=8, threshold=-3.2)
        trace = generate_collapse_trace(
            n_tokens=300, collapse_at=150, collapse_duration=5, seed=i * 7
        )
        detected = False
        for logits in trace:
            r = det.add_logits(logits)
            if r.collapsed:
                detected = True
        if detected:
            true_positives += 1

    sensitivity = true_positives / n_deceptive
    print(f"Sensitivity (TPR): {sensitivity:.1%} ({true_positives}/{n_deceptive})")

    # Test normal traces
    for i in range(n_normal):
        det = ShannonCollapseDetector(window_size=8, threshold=-3.2)
        trace = generate_normal_trace(n_tokens=300, seed=i * 13 + 1000)
        for logits in trace:
            r = det.add_logits(logits)
            if r.collapsed:
                false_positives += 1
                break

    fp_rate = false_positives / n_normal
    print(f"False positive rate: {fp_rate:.2%} ({false_positives}/{n_normal})")

    # ── Latency benchmark ────────────────────────────────────────

    det = ShannonCollapseDetector()
    bench_rng = np.random.default_rng(seed=0)
    warmup_logits = bench_rng.standard_normal(50000)
    for _ in range(10):
        det.add_logits(warmup_logits)

    det.reset()
    logits = bench_rng.standard_normal(50000)
    n_iter = 10000

    start = time.perf_counter()
    for _ in range(n_iter):
        det.add_logits(logits)
    elapsed = time.perf_counter() - start

    us_per_token = (elapsed / n_iter) * 1e6
    tok_per_sec = n_iter / elapsed
    print(f"\nLatency: {us_per_token:.1f} µs/token")
    print(f"Throughput: {tok_per_sec:,.0f} tokens/sec")
    print(f"Vocabulary size: 50,000")


if __name__ == "__main__":
    benchmark()
