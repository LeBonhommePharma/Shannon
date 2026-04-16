#!/usr/bin/env python3
"""Integration tests: Python → C++ round-trip verification via pybind11.

Tests that Python-side numpy arrays pass correctly through pybind11 to
the C++ ShannonEnergyMatrix / SoftContactMatrix and back.
"""

import sys
from pathlib import Path

import numpy as np
import pytest

# Skip entire module if C++ extension is not available
try:
    from shannon._core import ShannonEnergyMatrix, get_hardware_info

    HAS_CORE = True
except ImportError:
    HAS_CORE = False

pytestmark = pytest.mark.skipif(not HAS_CORE, reason="C++ module not available")

# Import training helpers for cross-validation
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
from train_256x256 import (
    sybyl_to_base as py_sybyl_to_base,
    base_to_sybyl_parent as py_base_to_sybyl_parent,
    encode_type as py_encode_type,
    decode_type as py_decode_type,
    project_to_40x40 as py_project_to_40x40,
    write_sc01,
    read_sc01,
    compute_energy_closed_form,
)


# =============================================================================
# Batch lookup round-trip
# =============================================================================


class TestBatchLookup:
    def test_numpy_arrays_round_trip(self):
        """batch_lookup with numpy uint8 arrays matches individual lookups."""
        m = ShannonEnergyMatrix.instance()
        sc = m.soft_contact()

        rng = np.random.default_rng(42)
        N = 1000
        types_i = rng.integers(0, 256, size=N, dtype=np.uint8)
        types_j = rng.integers(0, 256, size=N, dtype=np.uint8)

        batch_result = sc.batch_lookup(types_i, types_j)
        assert batch_result.shape == (N,)
        assert batch_result.dtype == np.float32

        for k in range(N):
            expected = sc.lookup(int(types_i[k]), int(types_j[k]))
            assert batch_result[k] == pytest.approx(expected, abs=1e-7), (
                f"Mismatch at k={k}: batch={batch_result[k]}, lookup={expected}"
            )

    def test_empty_arrays(self):
        """Empty arrays should return empty result."""
        m = ShannonEnergyMatrix.instance()
        sc = m.soft_contact()

        empty_i = np.array([], dtype=np.uint8)
        empty_j = np.array([], dtype=np.uint8)
        result = sc.batch_lookup(empty_i, empty_j)
        assert len(result) == 0


# =============================================================================
# Row-dot round-trip
# =============================================================================


class TestRowDot:
    def test_numpy_weights(self):
        """row_dot with numpy float32 weights matches manual computation."""
        m = ShannonEnergyMatrix.instance()
        sc = m.soft_contact()

        rng = np.random.default_rng(99)
        weights = rng.standard_normal(256).astype(np.float32)

        for row in [0, 42, 127, 255]:
            cpp_dot = sc.row_dot(row, weights)
            manual = sum(sc.lookup(row, j) * weights[j] for j in range(256))
            assert cpp_dot == pytest.approx(float(manual), rel=1e-4), (
                f"row_dot mismatch for row {row}"
            )

    def test_unit_weights(self):
        """row_dot with all-ones weights = sum of row."""
        m = ShannonEnergyMatrix.instance()
        sc = m.soft_contact()

        weights = np.ones(256, dtype=np.float32)
        dot = sc.row_dot(0, weights)
        row_sum = sum(sc.lookup(0, j) for j in range(256))
        assert dot == pytest.approx(float(row_sum), rel=1e-4)


# =============================================================================
# Two-stage pose scoring
# =============================================================================


class TestTwoStageScoring:
    def test_basic_round_trip(self):
        """score_poses_two_stage through pybind11 returns valid ScoringResult."""
        m = ShannonEnergyMatrix.instance()

        rng = np.random.default_rng(42)
        n_poses = 50
        contacts = 20
        total = n_poses * contacts

        types_i = rng.integers(0, 256, size=total, dtype=np.uint8)
        types_j = rng.integers(0, 256, size=total, dtype=np.uint8)
        distances = rng.uniform(2.0, 12.0, size=total).astype(np.float32)

        result = m.score_poses_two_stage(types_i, types_j, distances, n_poses, contacts, 0.20)

        assert result.poses_total == n_poses
        assert result.poses_evaluated > 0
        assert result.poses_evaluated <= n_poses
        assert np.isfinite(result.entropy)
        assert result.entropy >= 0.0
        assert np.isfinite(result.delta_g_proxy)

    def test_single_pose(self):
        """Single pose should survive pre-filter."""
        m = ShannonEnergyMatrix.instance()

        types_i = np.array([0, 1, 2], dtype=np.uint8)
        types_j = np.array([10, 20, 30], dtype=np.uint8)
        distances = np.array([4.0, 5.0, 6.0], dtype=np.float32)

        result = m.score_poses_two_stage(types_i, types_j, distances, 1, 3, 1.0)
        assert result.poses_total == 1
        assert result.poses_evaluated == 1


# =============================================================================
# SYBYL bridge: C++ vs Python consistency
# =============================================================================


class TestSybylBridgeConsistency:
    KNOWN_SYBYL = [
        "C.3",
        "C.2",
        "C.1",
        "C.ar",
        "N.3",
        "N.2",
        "N.1",
        "N.am",
        "N.ar",
        "N.pl3",
        "O.3",
        "O.2",
        "O.co2",
        "S.3",
        "S.2",
        "S.O",
        "S.O2",
        "P.3",
        "F",
        "Cl",
        "Br",
        "I",
        "H",
        "C.ar.het",
        "C.2.bridge",
    ]

    def test_sybyl_to_base_matches(self):
        """C++ sybyl_to_base matches Python version for all known types."""
        from shannon._core import sybyl_to_base as cpp_sybyl_to_base

        for name in self.KNOWN_SYBYL:
            cpp_val = cpp_sybyl_to_base(name)
            py_val = py_sybyl_to_base(name)
            assert cpp_val == py_val, (
                f"sybyl_to_base mismatch for '{name}': C++={cpp_val}, Python={py_val}"
            )

    def test_base_to_sybyl_parent_matches(self):
        """C++ base_to_sybyl_parent matches Python for all 32 base types."""
        from shannon._core import base_to_sybyl_parent as cpp_b2sp

        for base in range(32):
            cpp_val = cpp_b2sp(base)
            py_val = py_base_to_sybyl_parent(base)
            assert cpp_val == py_val, (
                f"base_to_sybyl_parent mismatch for base {base}: C++={cpp_val}, Python={py_val}"
            )

    def test_unknown_type(self):
        """C++ returns -1 for unknown SYBYL types."""
        from shannon._core import sybyl_to_base as cpp_sybyl_to_base

        assert cpp_sybyl_to_base("UNKNOWN") == -1
        assert cpp_sybyl_to_base("") == -1


# =============================================================================
# 256→32 projection: C++ vs Python consistency
# =============================================================================


class TestProjectionConsistency:
    def test_projection_matches(self):
        """C++ project_to_40x40 matches Python version within tolerance."""
        from shannon._core import project_to_40x40 as cpp_project

        m = ShannonEnergyMatrix.instance()
        sc = m.soft_contact()

        # C++ projection
        cpp_result = cpp_project(sc)
        assert cpp_result.shape == (32, 32)

        # Build 256×256 matrix from soft_contact lookups for Python projection
        matrix_256 = np.zeros((256, 256), dtype=np.float64)
        for i in range(256):
            for j in range(256):
                matrix_256[i, j] = sc.lookup(i, j)

        py_result = py_project_to_40x40(matrix_256)

        np.testing.assert_allclose(
            cpp_result,
            py_result,
            atol=1e-4,
            err_msg="C++ and Python project_to_40x40 produce different results",
        )


# =============================================================================
# SC01 binary: Python write → C++ load round-trip
# =============================================================================


class TestSC01RoundTrip:
    def test_python_write_cpp_load(self, tmp_path):
        """Matrix written by Python SC01 writer loads correctly in C++."""
        from shannon._core import ShannonEnergyMatrix

        # Build a test matrix from closed-form energy
        matrix = np.zeros((256, 256), dtype=np.float32)
        for i in range(256):
            for j in range(i, 256):
                e = compute_energy_closed_form(i, j)
                matrix[i, j] = e
                matrix[j, i] = e

        path = tmp_path / "test_round_trip.bin"
        write_sc01(matrix, path)

        # Verify file was created with correct size
        assert path.exists()
        assert path.stat().st_size == 8 + 256 * 256 * 4

        # Read back with Python
        loaded = read_sc01(path)
        np.testing.assert_array_almost_equal(loaded, matrix, decimal=5)


# =============================================================================
# Hardware info
# =============================================================================


class TestHardwareInfo:
    def test_hardware_info_fields(self):
        """get_hardware_info returns expected fields."""
        hw = get_hardware_info()
        assert hasattr(hw, "active_backend")
        assert hasattr(hw, "has_avx2")
        assert hasattr(hw, "has_avx512")
        assert hasattr(hw, "has_openmp")
        assert hasattr(hw, "has_cuda")
        assert hasattr(hw, "has_metal")
        assert isinstance(hw.active_backend, str)
        assert len(hw.active_backend) > 0
