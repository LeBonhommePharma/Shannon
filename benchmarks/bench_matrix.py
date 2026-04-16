#!/usr/bin/env python3
"""Benchmark: 256×256 matrix operations — single lookup, batch, row-dot, two-stage scoring.

Usage:
    python benchmarks/bench_matrix.py [--json]
"""

from __future__ import annotations

import argparse
import json
import time
import sys
from datetime import datetime, timezone

import numpy as np


def format_ns(total_seconds: float, n_ops: int) -> str:
    """Format timing as nanoseconds per operation."""
    ns = total_seconds * 1e9 / n_ops
    return f"{ns:.2f} ns/op"


def ns_per_op(total_seconds: float, n_ops: int) -> float:
    return total_seconds * 1e9 / n_ops


def bench_single_lookup() -> float | None:
    """Benchmark: 10M individual lookups via SoftContactMatrix.lookup()."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available", file=sys.stderr)
        return None

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

    print(f"  Single lookup: {N:,} ops in {elapsed:.3f}s = {format_ns(elapsed, N)}", file=sys.stderr)
    return ns_per_op(elapsed, N)


def bench_batch_lookup() -> float | None:
    """Benchmark: 10M lookups via batch_lookup() (SIMD accelerated)."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available", file=sys.stderr)
        return None

    m = ShannonEnergyMatrix.instance()
    sc = m.soft_contact()

    N = 10_000_000
    rng = np.random.default_rng(42)
    types_i = rng.integers(0, 256, size=N, dtype=np.uint8)
    types_j = rng.integers(0, 256, size=N, dtype=np.uint8)

    # Warm up
    sc.batch_lookup(types_i[:1000], types_j[:1000])

    start = time.perf_counter()
    sc.batch_lookup(types_i, types_j)
    elapsed = time.perf_counter() - start

    print(f"  Batch lookup:  {N:,} ops in {elapsed:.3f}s = {format_ns(elapsed, N)}", file=sys.stderr)
    return ns_per_op(elapsed, N)


def bench_row_dot() -> float | None:
    """Benchmark: 1M row-dot operations (FMA accelerated)."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available", file=sys.stderr)
        return None

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

    print(f"  Row-dot:       {N:,} ops in {elapsed:.3f}s = {format_ns(elapsed, N)}", file=sys.stderr)
    return ns_per_op(elapsed, N)


def bench_two_stage() -> dict | None:
    """Benchmark: two-stage pose scoring (10K poses × 50 contacts)."""
    try:
        from shannon._core import ShannonEnergyMatrix
    except ImportError:
        print("  [SKIP] C++ module not available", file=sys.stderr)
        return None

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

    print(f"  Two-stage:     {N_POSES:,} poses × {CONTACTS} contacts in {elapsed:.3f}s", file=sys.stderr)
    print(f"                 Survived pre-filter: {result.poses_evaluated}/{result.poses_total}", file=sys.stderr)
    print(f"                 Entropy: {result.entropy:.4f} bits", file=sys.stderr)
    print(f"                 ΔG proxy: {result.delta_g_proxy:.4f} kcal/mol", file=sys.stderr)

    return {
        "two_stage_ms": elapsed * 1000,
        "two_stage_poses": N_POSES,
        "two_stage_contacts": CONTACTS,
        "two_stage_survival_rate": result.poses_evaluated / result.poses_total if result.poses_total > 0 else 0,
        "two_stage_entropy": result.entropy,
        "two_stage_delta_g": result.delta_g_proxy,
    }


def main():
    parser = argparse.ArgumentParser(description="Shannon 256×256 matrix benchmarks")
    parser.add_argument("--json", action="store_true", help="Output structured JSON to stdout")
    args = parser.parse_args()

    print("=" * 60, file=sys.stderr)
    print("Shannon 256×256 Matrix Benchmark", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    backend = "unknown"
    hw_info = {}
    try:
        from shannon._core import get_hardware_info
        hw = get_hardware_info()
        backend = hw.active_backend
        hw_info = {
            "avx512": hw.has_avx512,
            "avx2": hw.has_avx2,
            "openmp": hw.has_openmp,
            "cuda": hw.has_cuda,
            "metal": hw.has_metal,
        }
        print(f"Backend: {hw.active_backend}", file=sys.stderr)
        print(f"  AVX-512: {hw.has_avx512}", file=sys.stderr)
        print(f"  AVX2:    {hw.has_avx2}", file=sys.stderr)
        print(f"  OpenMP:  {hw.has_openmp}", file=sys.stderr)
        print(f"  CUDA:    {hw.has_cuda}", file=sys.stderr)
        print(f"  Metal:   {hw.has_metal}", file=sys.stderr)
    except ImportError:
        print("C++ module not available — benchmarks will be skipped", file=sys.stderr)
        if args.json:
            json.dump({"error": "C++ module not available"}, sys.stdout, indent=2)
        else:
            sys.exit(1)
        return

    print(file=sys.stderr)
    print("--- Matrix Operations ---", file=sys.stderr)
    single_ns = bench_single_lookup()
    batch_ns = bench_batch_lookup()
    row_dot_ns = bench_row_dot()
    print(file=sys.stderr)
    print("--- Pose Scoring ---", file=sys.stderr)
    two_stage = bench_two_stage()
    print(file=sys.stderr)
    print("Done.", file=sys.stderr)

    if args.json:
        results = {
            "benchmark": "bench_matrix",
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "backend": backend,
            "hardware": hw_info,
            "single_lookup_ns": single_ns,
            "batch_lookup_ns": batch_ns,
            "row_dot_ns": row_dot_ns,
        }
        if two_stage:
            results.update(two_stage)
        json.dump(results, sys.stdout, indent=2)
        print()  # trailing newline


if __name__ == "__main__":
    main()
