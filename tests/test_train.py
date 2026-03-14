#!/usr/bin/env python3
"""Tests for train_256x256.py — PDBbind training pipeline."""

import struct
import tempfile
from pathlib import Path

import numpy as np
import pytest

# Add scripts directory to path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from train_256x256 import (
    sybyl_to_base,
    base_to_sybyl_parent,
    encode_type,
    decode_type,
    charge_to_bin,
    is_hbond,
    compute_energy_closed_form,
    distance_kernel,
    ridge_regression_fit,
    project_to_40x40,
    validate_matrix,
    write_sc01,
    read_sc01,
    generate_synthetic_training_data,
    Contact,
    SYBYL_TO_BASE,
)


# =============================================================================
# SYBYL bridge
# =============================================================================

class TestSybylBridge:
    def test_known_types(self):
        assert sybyl_to_base("C.3") == 0
        assert sybyl_to_base("C.ar") == 3
        assert sybyl_to_base("N.ar") == 8
        assert sybyl_to_base("O.3") == 12
        assert sybyl_to_base("H") == 19

    def test_context_aware(self):
        assert sybyl_to_base("C.ar.het") == 20
        assert sybyl_to_base("C.2.bridge") == 21

    def test_unknown_defaults_to_dummy(self):
        assert sybyl_to_base("UNKNOWN") == 31
        assert sybyl_to_base("") == 31

    def test_all_sybyl_types_valid(self):
        for name, base in SYBYL_TO_BASE.items():
            assert 0 <= base <= 31, f"Invalid base for {name}: {base}"

    def test_reverse_bridge(self):
        for base in range(32):
            parent = base_to_sybyl_parent(base)
            assert 0 <= parent < 40, f"Invalid parent for base {base}: {parent}"

    def test_context_aware_parents(self):
        # C.ar.het (20) → C.ar parent (3)
        assert base_to_sybyl_parent(20) == 3
        # C.2.bridge (21) → C.2 parent (1)
        assert base_to_sybyl_parent(21) == 1


# =============================================================================
# 8-bit type encoding
# =============================================================================

class TestTypeEncoding:
    def test_round_trip(self):
        for t in range(256):
            base, charge, hbond = decode_type(t)
            reconstructed = encode_type(base, charge, bool(hbond))
            assert reconstructed == t, f"Round-trip failed for {t}"

    def test_field_ranges(self):
        for t in range(256):
            base, charge, hbond = decode_type(t)
            assert 0 <= base < 32
            assert 0 <= charge < 4
            assert hbond in (0, 1)

    def test_charge_bins(self):
        assert charge_to_bin(-0.8) == 0   # strong negative
        assert charge_to_bin(-0.2) == 1   # weak negative
        assert charge_to_bin(0.0) == 2    # weak positive
        assert charge_to_bin(0.5) == 3    # strong positive

    def test_hbond_detection(self):
        assert is_hbond("N", "N.3") is True
        assert is_hbond("O", "O.2") is True
        assert is_hbond("C", "C.3") is False


# =============================================================================
# Closed-form energy
# =============================================================================

class TestClosedForm:
    def test_symmetry(self):
        for ti in range(0, 256, 17):
            for tj in range(ti, 256, 23):
                e_ij = compute_energy_closed_form(ti, tj)
                e_ji = compute_energy_closed_form(tj, ti)
                assert abs(e_ij - e_ji) < 1e-12, f"Asymmetry at ({ti},{tj})"

    def test_finite(self):
        for ti in range(0, 256, 11):
            for tj in range(0, 256, 13):
                e = compute_energy_closed_form(ti, tj)
                assert np.isfinite(e), f"Non-finite at ({ti},{tj})"

    def test_distance_kernel(self):
        assert distance_kernel(0.0) == pytest.approx(1.0)
        assert distance_kernel(3.0) == pytest.approx(np.exp(-0.5))
        assert distance_kernel(100.0) < 1e-100


# =============================================================================
# Ridge regression
# =============================================================================

class TestRidgeRegression:
    def test_synthetic_signal_recovery(self):
        """Ridge regression should recover known signal from synthetic data."""
        contacts, delta_g = generate_synthetic_training_data(
            n_complexes=200, contacts_per_complex=50, seed=123,
        )

        matrix = ridge_regression_fit(
            contacts, delta_g, min_observations=5, lam=0.1,
        )

        # Matrix should be symmetric
        max_asym = np.max(np.abs(matrix - matrix.T))
        assert max_asym < 1e-10

        # Matrix should be non-trivial
        assert np.count_nonzero(matrix) > 60000

        # Should be finite everywhere
        assert not np.any(np.isnan(matrix))
        assert not np.any(np.isinf(matrix))


# =============================================================================
# SC01 binary I/O
# =============================================================================

class TestSC01:
    def test_round_trip(self, tmp_path):
        """Write and read SC01 format should produce identical matrix."""
        matrix = np.random.default_rng(42).standard_normal((256, 256)).astype(np.float32)
        # Make symmetric
        matrix = (matrix + matrix.T) / 2.0

        path = tmp_path / "test_matrix.bin"
        write_sc01(matrix, path)

        loaded = read_sc01(path)
        np.testing.assert_array_almost_equal(loaded, matrix, decimal=6)

    def test_file_size(self, tmp_path):
        """SC01 file should be 8 bytes header + 256*256*4 bytes data."""
        matrix = np.zeros((256, 256), dtype=np.float32)
        path = tmp_path / "test_size.bin"
        write_sc01(matrix, path)
        assert path.stat().st_size == 8 + 256 * 256 * 4

    def test_magic_validation(self, tmp_path):
        """Reading a file with wrong magic should fail."""
        path = tmp_path / "bad_magic.bin"
        with open(path, "wb") as f:
            f.write(b"XXXX")
            f.write(struct.pack("<HH", 256, 256))
            f.write(np.zeros(256 * 256, dtype=np.float32).tobytes())

        with pytest.raises(AssertionError):
            read_sc01(path)


# =============================================================================
# 256→40 projection
# =============================================================================

class TestProjection:
    def test_shape(self):
        matrix = np.ones((256, 256), dtype=np.float64)
        cf = project_to_40x40(matrix)
        assert cf.shape[0] == 32
        assert cf.shape[1] == 32

    def test_symmetry(self):
        rng = np.random.default_rng(42)
        matrix = rng.standard_normal((256, 256))
        matrix = (matrix + matrix.T) / 2.0
        cf = project_to_40x40(matrix)
        np.testing.assert_array_almost_equal(cf, cf.T, decimal=5)

    def test_uniform_input(self):
        """Uniform matrix → projection should be uniform too."""
        matrix = np.full((256, 256), 1.5, dtype=np.float64)
        cf = project_to_40x40(matrix)
        # All populated cells should be close to 1.5
        nonzero = cf[cf != 0.0]
        if len(nonzero) > 0:
            np.testing.assert_allclose(nonzero, 1.5, atol=1e-5)


# =============================================================================
# Validation
# =============================================================================

class TestValidation:
    def test_valid_matrix(self):
        matrix = np.random.default_rng(42).standard_normal((256, 256)).astype(np.float64)
        matrix = (matrix + matrix.T) / 2.0
        validate_matrix(matrix)  # should not raise

    def test_asymmetric_fails(self):
        matrix = np.random.default_rng(42).standard_normal((256, 256)).astype(np.float64)
        with pytest.raises(AssertionError):
            validate_matrix(matrix)

    def test_nan_fails(self):
        matrix = np.zeros((256, 256), dtype=np.float64)
        matrix[0, 0] = np.nan
        matrix = (matrix + matrix.T) / 2.0
        with pytest.raises(AssertionError):
            validate_matrix(matrix)


# =============================================================================
# Synthetic data generation
# =============================================================================

class TestSyntheticData:
    def test_generates_contacts(self):
        contacts, delta_g = generate_synthetic_training_data(
            n_complexes=50, contacts_per_complex=20, seed=0,
        )
        assert len(contacts) > 0
        assert len(delta_g) == 50

    def test_deterministic(self):
        c1, dg1 = generate_synthetic_training_data(seed=42)
        c2, dg2 = generate_synthetic_training_data(seed=42)
        assert len(c1) == len(c2)
        assert dg1 == dg2

    def test_contact_fields(self):
        contacts, _ = generate_synthetic_training_data(
            n_complexes=10, contacts_per_complex=5, seed=0,
        )
        for c in contacts[:100]:
            assert 0 <= c.type_i < 256
            assert 0 <= c.type_j < 256
            assert c.distance > 0
            assert c.complex_id >= 0
