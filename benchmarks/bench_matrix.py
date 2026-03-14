#!/usr/bin/env python3
"""Benchmark: 256×256 matrix operations — single lookup, batch, row-dot, two-stage scoring.

Usage:
    python benchmarks/bench_matrix.py
"""

from __future__ import annotations

import time
import sys

import numpy as np


def format_ns(total_seconds: float, n_ops: int) -> str:
    """Format timing as nanoseconds per operation."""
    ns = total_seconds * 1e9 / n_ops
    return f"{ns:.2f} ns/op"


def bench_single_lookup():
    """Benchmark: 10M individual lookups via SoftContactMatrix.lookup()."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available")
        return

    m = ShannonEnergyMatrix.instance()
    sc = m.soft_contact()

    N = 10_000_000
    rng = np.random.default_rng(42)
    types_i = rng.integers(0, 256, size=N, dtype=np.uint8)
    types_j = rng.integers(0, 256, size=N, dtype=np.uint8)

    # Warm up
    for k in range(1000):
        sc.lookup(int(types_i[k]), int(types_j[k]))

    start = time.perf_counter()
    for k in range(N):
        sc.lookup(int(types_i[k]), int(types_j[k]))
    elapsed = time.perf_counter() - start

    print(f"  Single lookup: {N:,} ops in {elapsed:.3f}s = {format_ns(elapsed, N)}")


def bench_batch_lookup():
    """Benchmark: 10M lookups via batch_lookup() (SIMD accelerated)."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available")
        return

    m = ShannonEnergyMatrix.instance()
    sc = m.soft_contact()

    N = 10_000_000
    rng = np.random.default_rng(42)
    types_i = rng.integers(0, 256, size=N, dtype=np.uint8)
    types_j = rng.integers(0, 256, size=N, dtype=np.uint8)

    # Warm up
    sc.batch_lookup(types_i[:1000], types_j[:1000])

    start = time.perf_counter()
    scores = sc.batch_lookup(types_i, types_j)
    elapsed = time.perf_counter() - start

    print(f"  Batch lookup:  {N:,} ops in {elapsed:.3f}s = {format_ns(elapsed, N)}")
    return scores


def bench_row_dot():
    """Benchmark: 1M row-dot operations (FMA accelerated)."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available")
        return

    m = ShannonEnergyMatrix.instance()
    sc = m.soft_contact()

    N = 1_000_000
    rng = np.random.default_rng(42)
    weights = rng.standard_normal(256).astype(np.float32)

    # Warm up
    for _ in range(100):
        sc.row_dot(42, weights)

    start = time.perf_counter()
    for k in range(N):
        sc.row_dot(k % 256, weights)
    elapsed = time.perf_counter() - start

    print(f"  Row-dot:       {N:,} ops in {elapsed:.3f}s = {format_ns(elapsed, N)}")


def bench_two_stage():
    """Benchmark: two-stage pose scoring (10K poses × 50 contacts)."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available")
        return

    m = ShannonEnergyMatrix.instance()

    N_POSES = 10_000
    CONTACTS = 50
    total = N_POSES * CONTACTS
    rng = np.random.default_rng(42)

    types_i = rng.integers(0, 256, size=total, dtype=np.uint8)
    types_j = rng.integers(0, 256, size=total, dtype=np.uint8)
    distances = rng.uniform(2.0, 12.0, size=total).astype(np.float32)

    # Warm up
    m.score_poses_two_stage(
        types_i[:500], types_j[:500], distances[:500], 10, 50, 0.10)

    start = time.perf_counter()
    result = m.score_poses_two_stage(
        types_i, types_j, distances, N_POSES, CONTACTS, 0.10)
    elapsed = time.perf_counter() - start

    print(f"  Two-stage:     {N_POSES:,} poses × {CONTACTS} contacts in {elapsed:.3f}s")
    print(f"                 Survived pre-filter: {result.poses_evaluated}/{result.poses_total}")
    print(f"                 Entropy: {result.entropy:.4f} bits")
    print(f"                 ΔG proxy: {result.delta_g_proxy:.4f} kcal/mol")


def main():
    print("=" * 60)
    print("Shannon 256×256 Matrix Benchmark")
    print("=" * 60)

    try:
        from shannon._core import get_hardware_info
        hw = get_hardware_info()
        print(f"Backend: {hw.active_backend}")
        print(f"  AVX-512: {hw.has_avx512}")
        print(f"  AVX2:    {hw.has_avx2}")
        print(f"  OpenMP:  {hw.has_openmp}")
        print(f"  CUDA:    {hw.has_cuda}")
        print(f"  Metal:   {hw.has_metal}")
    except ImportError:
        print("C++ module not available — benchmarks will be skipped")
        sys.exit(1)

    print()
    print("--- Matrix Operations ---")
    bench_single_lookup()
    bench_batch_lookup()
    bench_row_dot()
    print()
    print("--- Pose Scoring ---")
    bench_two_stage()
    print()
    print("Done.")


if __name__ == "__main__":
    main()
