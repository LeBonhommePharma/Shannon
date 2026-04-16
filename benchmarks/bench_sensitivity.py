#!/usr/bin/env python3
"""Shannon — Sensitivity and Performance Benchmarks

Measures:
1. Throughput: tokens/sec across vocabulary sizes
2. Backend comparison: C++ vs Numba vs NumPy
3. Collapse detection sensitivity on synthetic patterns

Usage:
    python benchmarks/bench_sensitivity.py [--json]
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from typing import Callable

import numpy as np

import shannon
from shannon._numba_fallback import (
    _shannon_entropy_numpy,
    _shannon_entropy_from_logits_numpy,
    get_fallback_backend,
)


def bench_entropy_throughput(
    fn: Callable,
    vocab_sizes: list[int],
    n_iters: int = 1000,
    label: str = "",
) -> dict[int, float]:
    """Benchmark entropy computation throughput."""
    results = {}
    for vocab in vocab_sizes:
        logits = np.random.randn(vocab).astype(np.float64)
        # Warmup
        for _ in range(10):
            fn(logits)
        # Timed
        start = time.perf_counter()
        for _ in range(n_iters):
            fn(logits)
        elapsed = time.perf_counter() - start
        tokens_per_sec = n_iters / elapsed
        us_per_call = elapsed / n_iters * 1e6
        results[vocab] = us_per_call
        print(f"  {label:>10s}  vocab={vocab:>7d}  {us_per_call:8.1f} us/call  {tokens_per_sec:10.0f} tok/s",
              file=sys.stderr)
    return results


def bench_collapse_sensitivity() -> dict:
    """Test collapse detection on synthetic patterns."""
    print("\n=== Collapse Detection Sensitivity ===\n", file=sys.stderr)

    np.random.seed(42)
    n_trials = 1000
    tp = fp = tn = fn_count = 0

    for _ in range(n_trials):
        detector = shannon.ShannonCollapseDetector(window_size=8, collapse_threshold=-3.2)

        # Phase 1: Normal generation (uniform-ish logits)
        for _ in range(20):
            logits = np.random.randn(32000) * 2.0
            detector.add_logits(logits)

        was_collapsed_before = detector.is_collapsed

        # Phase 2: Collapse (one token dominates increasingly)
        for i in range(10):
            logits = np.random.randn(32000) * 0.1
            logits[0] = float(i * 10)  # Increasingly dominant
            detector.add_logits(logits)

        is_collapsed_after = detector.is_collapsed

        if is_collapsed_after and not was_collapsed_before:
            tp += 1
        elif is_collapsed_after and was_collapsed_before:
            fp += 1  # Was already collapsed — false signal
        elif not is_collapsed_after:
            fn_count += 1

    # No-collapse trials
    for _ in range(n_trials):
        detector = shannon.ShannonCollapseDetector(window_size=8, collapse_threshold=-3.2)
        for _ in range(30):
            logits = np.random.randn(32000) * 2.0
            detector.add_logits(logits)
        if detector.is_collapsed:
            fp += 1
        else:
            tn += 1

    sensitivity = tp / (tp + fn_count) if (tp + fn_count) > 0 else 0
    specificity = tn / (tn + fp) if (tn + fp) > 0 else 0
    fpr = fp / (fp + tn) if (fp + tn) > 0 else 0

    print(f"Trials: {n_trials} collapse + {n_trials} no-collapse", file=sys.stderr)
    print(f"TP={tp}  FP={fp}  TN={tn}  FN={fn_count}", file=sys.stderr)
    print(f"Sensitivity: {sensitivity:.1%}", file=sys.stderr)
    print(f"Specificity: {specificity:.1%}", file=sys.stderr)
    print(f"False positive rate: {fpr:.3%}", file=sys.stderr)

    return {
        "n_trials": n_trials,
        "tp": tp, "fp": fp, "tn": tn, "fn": fn_count,
        "sensitivity": sensitivity,
        "specificity": specificity,
        "fpr": fpr,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Shannon sensitivity & throughput benchmarks")
    parser.add_argument("--json", action="store_true", help="Output structured JSON to stdout")
    args = parser.parse_args()

    print("Shannon Entropy — Performance Benchmarks", file=sys.stderr)
    print(f"Version: {shannon.__version__}", file=sys.stderr)
    print(f"C++ core: {shannon._HAS_CORE}", file=sys.stderr)
    print(f"Fallback backend: {get_fallback_backend()}", file=sys.stderr)
    print(file=sys.stderr)

    vocab_sizes = [100, 1000, 10000, 32000, 128000]
    all_throughput = {}

    # NumPy baseline
    print("=== NumPy Baseline ===", file=sys.stderr)
    numpy_results = bench_entropy_throughput(
        _shannon_entropy_from_logits_numpy,
        vocab_sizes,
        n_iters=100,
        label="numpy",
    )
    all_throughput["numpy"] = {str(k): v for k, v in numpy_results.items()}

    # Numba (if available)
    if get_fallback_backend() == "numba":
        from shannon._numba_fallback import _shannon_entropy_from_logits_numba
        print("\n=== Numba ===", file=sys.stderr)
        numba_results = bench_entropy_throughput(
            _shannon_entropy_from_logits_numba,
            vocab_sizes,
            n_iters=100,
            label="numba",
        )
        all_throughput["numba"] = {str(k): v for k, v in numba_results.items()}

    # C++ core (if available)
    if shannon._HAS_CORE:
        print("\n=== C++ Core ===", file=sys.stderr)
        cpp_results = bench_entropy_throughput(
            shannon.shannon_entropy_from_logits,
            vocab_sizes,
            n_iters=1000,
            label="cpp",
        )
        all_throughput["cpp"] = {str(k): v for k, v in cpp_results.items()}

        info = shannon.get_hardware_info()
        print(f"\nActive backend: {info.active_backend}", file=sys.stderr)

    # Collapse sensitivity
    sensitivity_results = bench_collapse_sensitivity()

    if args.json:
        output = {
            "benchmark": "bench_sensitivity",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "version": shannon.__version__,
            "has_cpp_core": shannon._HAS_CORE,
            "fallback_backend": get_fallback_backend(),
            "throughput_us_per_call": all_throughput,
            "collapse_sensitivity": sensitivity_results,
        }
        json.dump(output, sys.stdout, indent=2)
        print()  # trailing newline


if __name__ == "__main__":
    main()
