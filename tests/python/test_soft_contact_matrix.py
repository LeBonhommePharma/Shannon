# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT

"""Tests for the 256×256 soft contact matrix module."""

import struct
import tempfile
from pathlib import Path

import numpy as np
import pytest

from shannon_contact.matrix import (
    SoftContactMatrix,
    NUM_ATOM_TYPES,
    MATRIX_SIZE,
    MATRIX_BYTES,
    SCM_MAGIC,
    SCM_HEADER_SIZE,
    SC01_MAGIC,
    SC01_HEADER_SIZE,
    ATOM_TYPE_SCHEMA_ID,
    get_backend,
)
from shannon_contact.atom_typer import (
    encode_atom_type,
    decode_atom_type,
    bin_partial_charge,
    ATOM_TYPE_SCHEMA_ID as TYPER_SCHEMA_ID,
)


# ─── Encoding / Decoding ────────────────────────────────────────────────────


class TestEncoding:
    def test_round_trip_all_values(self):
        """All 256 combinations encode/decode correctly."""
        seen = set()
        for base in range(32):
            for charge in range(4):
                for hbond in range(2):
                    encoded = encode_atom_type(base, charge, hbond)
                    assert 0 <= encoded <= 255
                    assert encoded not in seen
                    seen.add(encoded)
                    b, c, h = decode_atom_type(encoded)
                    assert b == base
                    assert c == charge
                    assert h == hbond
        assert len(seen) == 256

    def test_charge_binning(self):
        assert bin_partial_charge(-0.5) == 0   # StrongNeg
        assert bin_partial_charge(-0.1) == 1   # WeakNeg
        assert bin_partial_charge(0.1) == 2    # WeakPos
        assert bin_partial_charge(0.5) == 3    # StrongPos

    def test_charge_bin_boundaries(self):
        assert bin_partial_charge(-0.25) == 1  # boundary: WeakNeg
        assert bin_partial_charge(0.0) == 2    # boundary: WeakPos
        assert bin_partial_charge(0.25) == 3   # boundary: StrongPos


# ─── Matrix Creation ────────────────────────────────────────────────────────


class TestMatrixCreation:
    def test_default_zero(self):
        m = SoftContactMatrix()
        arr = m.to_numpy()
        assert arr.shape == (256, 256)
        assert arr.dtype == np.float32
        assert np.all(arr == 0.0)

    def test_from_numpy(self):
        rng = np.random.default_rng(42)
        data = rng.standard_normal((256, 256)).astype(np.float32)
        m = SoftContactMatrix(data=data)
        np.testing.assert_array_equal(m.to_numpy(), data)

    def test_from_flat_numpy(self):
        data = np.ones(MATRIX_SIZE, dtype=np.float32) * 3.14
        m = SoftContactMatrix(data=data)
        arr = m.to_numpy()
        assert arr.shape == (256, 256)
        assert np.allclose(arr, 3.14)


# ─── Lookup ──────────────────────────────────────────────────────────────────


class TestLookup:
    def test_basic_lookup(self):
        m = SoftContactMatrix()
        m.set(10, 20, 3.14)
        assert m.lookup(10, 20) == pytest.approx(3.14)
        assert m.lookup(0, 0) == 0.0

    def test_lookup_matches_numpy(self):
        rng = np.random.default_rng(42)
        data = rng.standard_normal((256, 256)).astype(np.float32)
        m = SoftContactMatrix(data=data)
        for _ in range(100):
            i = rng.integers(0, 256)
            j = rng.integers(0, 256)
            assert m.lookup(i, j) == pytest.approx(float(data[i, j]))


# ─── Symmetry ────────────────────────────────────────────────────────────────


class TestSymmetry:
    def test_zero_is_symmetric(self):
        m = SoftContactMatrix()
        assert m.is_symmetric()

    def test_symmetrize(self):
        m = SoftContactMatrix()
        m.set(5, 10, 4.0)
        m.set(10, 5, 2.0)
        assert not m.is_symmetric()
        m.symmetrize()
        assert m.is_symmetric()
        assert m.lookup(5, 10) == pytest.approx(3.0)
        assert m.lookup(10, 5) == pytest.approx(3.0)


# ─── File I/O ────────────────────────────────────────────────────────────────


class TestFileIO:
    def test_save_load_round_trip(self, tmp_path):
        rng = np.random.default_rng(42)
        data = rng.standard_normal((256, 256)).astype(np.float32)
        m = SoftContactMatrix(data=data)

        path = tmp_path / "matrix.bin"
        m.save(str(path))

        m2 = SoftContactMatrix(path=str(path))
        np.testing.assert_array_equal(m.to_numpy(), m2.to_numpy())

    def test_load_raw_blob(self, tmp_path):
        data = np.ones(MATRIX_SIZE, dtype=np.float32) * 2.0
        path = tmp_path / "raw.bin"
        path.write_bytes(data.tobytes())

        m = SoftContactMatrix(path=str(path))
        assert np.allclose(m.to_numpy(), 2.0)

    def test_load_sc01_legacy_header(self, tmp_path):
        data = np.ones((256, 256), dtype=np.float32) * 4.0
        path = tmp_path / "matrix.sc01"
        path.write_bytes(
            SC01_MAGIC + struct.pack("<HH", 256, 256) + data.tobytes()
        )

        m = SoftContactMatrix(path=str(path))
        assert np.allclose(m.to_numpy(), 4.0)

    def test_reject_flexaidds_shnn_schema(self, tmp_path):
        path = tmp_path / "flexaidds.shnn"
        path.write_bytes(
            b"SHNN" + struct.pack("<II", 1, 256)
            + np.zeros((256, 256), dtype=np.float32).tobytes()
        )
        with pytest.raises(
            (ValueError, RuntimeError), match="schema mismatch|FlexAIDdS"
        ):
            SoftContactMatrix(path=str(path))

    def test_schema_constants_match(self):
        assert ATOM_TYPE_SCHEMA_ID == TYPER_SCHEMA_ID
        assert "base32.charge4.hbond1" in ATOM_TYPE_SCHEMA_ID

    def test_load_invalid_size_raises(self, tmp_path):
        path = tmp_path / "bad.bin"
        path.write_bytes(b"short")
        with pytest.raises((ValueError, RuntimeError)):
            SoftContactMatrix(path=str(path))

    def test_project_to_superclusters(self):
        data = np.zeros((256, 256), dtype=np.float32)
        data[0, 2] = 1.0
        data[0, 3] = 3.0
        data[1, 2] = 5.0
        data[1, 3] = 7.0
        labels = [-1] * 256
        labels[0] = labels[1] = 0
        labels[2] = labels[3] = 1

        reduced = SoftContactMatrix(data=data).project_to_superclusters(labels)
        assert reduced[0, 1] == pytest.approx(4.0)

# ─── Contact Scoring ────────────────────────────────────────────────────────


class TestScoring:
    def test_score_contacts(self):
        m = SoftContactMatrix()
        m.set(1, 2, 5.0)
        m.set(3, 4, 3.0)

        types_i = np.array([1, 3], dtype=np.uint8)
        types_j = np.array([2, 4], dtype=np.uint8)
        weights = np.array([1.0, 2.0], dtype=np.float32)

        score = m.score_contacts(types_i, types_j, weights)
        assert score == pytest.approx(5.0 + 6.0)

    def test_score_no_weights(self):
        m = SoftContactMatrix()
        m.set(1, 2, 5.0)

        types_i = np.array([1], dtype=np.uint8)
        types_j = np.array([2], dtype=np.uint8)

        score = m.score_contacts(types_i, types_j)
        assert score == pytest.approx(5.0)


# ─── Pose Activation ────────────────────────────────────────────────────────


class TestPoseActivation:
    def test_activation_shape(self):
        m = SoftContactMatrix()
        types_i = np.array([1, 3], dtype=np.uint8)
        types_j = np.array([2, 4], dtype=np.uint8)
        act = m.pose_activation(types_i, types_j)
        assert act.shape == (256,)
        assert act.dtype == np.float32

    def test_activation_values(self):
        m = SoftContactMatrix()
        m.set(1, 2, 5.0)

        types_i = np.array([1], dtype=np.uint8)
        types_j = np.array([2], dtype=np.uint8)
        weights = np.array([1.0], dtype=np.float32)

        act = m.pose_activation(types_i, types_j, weights)
        assert act[1] == pytest.approx(5.0)
        assert act[2] == pytest.approx(5.0)
        assert act[0] == 0.0


# ─── Backend ─────────────────────────────────────────────────────────────────


class TestEdgeCases:
    def test_score_empty_contacts(self):
        m = SoftContactMatrix()
        m.set(1, 2, 5.0)
        types_i = np.array([], dtype=np.uint8)
        types_j = np.array([], dtype=np.uint8)
        weights = np.array([], dtype=np.float32)
        assert m.score_contacts(types_i, types_j, weights) == pytest.approx(0.0)

    def test_activation_empty_contacts(self):
        m = SoftContactMatrix()
        types_i = np.array([], dtype=np.uint8)
        types_j = np.array([], dtype=np.uint8)
        weights = np.array([], dtype=np.float32)
        act = m.pose_activation(types_i, types_j, weights)
        assert act.shape == (256,)
        assert np.all(act == 0.0)


# ─── PoseEncoder ────────────────────────────────────────────────────────────


class TestPoseEncoder:
    @pytest.fixture()
    def matrix_and_encoder(self):
        from shannon_contact.pose_encoder import PoseEncoder

        m = SoftContactMatrix()
        # Set up a known interaction: type 1 <-> type 2 = 5.0
        m.set(1, 2, 5.0)
        m.set(2, 1, 5.0)
        encoder = PoseEncoder(m, cutoff=6.0, sigma=2.0)
        return m, encoder

    def test_encode_pose_known_geometry(self, matrix_and_encoder):
        """Two atoms within cutoff produce expected activation."""
        _, encoder = matrix_and_encoder

        protein_types = np.array([1], dtype=np.uint8)
        ligand_types = np.array([2], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0]])
        ligand_coords = np.array([[3.0, 0.0, 0.0]])  # distance = 3.0

        act = encoder.encode_pose(
            protein_types, ligand_types, protein_coords, ligand_coords
        )
        assert act.shape == (256,)
        # Weight = exp(-0.5 * (3.0/2.0)^2) = exp(-1.125) ≈ 0.3247
        expected_weight = float(np.exp(-0.5 * (3.0 / 2.0) ** 2))
        expected_val = 5.0 * expected_weight
        assert act[1] == pytest.approx(expected_val, rel=1e-4)
        assert act[2] == pytest.approx(expected_val, rel=1e-4)

    def test_encode_pose_no_contacts(self, matrix_and_encoder):
        """Atoms beyond cutoff produce zero activation."""
        _, encoder = matrix_and_encoder

        protein_types = np.array([1], dtype=np.uint8)
        ligand_types = np.array([2], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0]])
        ligand_coords = np.array([[100.0, 0.0, 0.0]])  # far beyond cutoff

        act = encoder.encode_pose(
            protein_types, ligand_types, protein_coords, ligand_coords
        )
        assert np.all(act == 0.0)

    def test_score_pose(self, matrix_and_encoder):
        """score_pose returns a float energy."""
        _, encoder = matrix_and_encoder

        protein_types = np.array([1], dtype=np.uint8)
        ligand_types = np.array([2], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0]])
        ligand_coords = np.array([[3.0, 0.0, 0.0]])

        score = encoder.score_pose(
            protein_types, ligand_types, protein_coords, ligand_coords
        )
        expected_weight = float(np.exp(-0.5 * (3.0 / 2.0) ** 2))
        assert score == pytest.approx(5.0 * expected_weight, rel=1e-4)

    def test_score_pose_no_contacts(self, matrix_and_encoder):
        _, encoder = matrix_and_encoder
        protein_types = np.array([1], dtype=np.uint8)
        ligand_types = np.array([2], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0]])
        ligand_coords = np.array([[100.0, 0.0, 0.0]])

        assert encoder.score_pose(
            protein_types, ligand_types, protein_coords, ligand_coords
        ) == 0.0

    def test_encode_ensemble(self, matrix_and_encoder):
        """encode_ensemble returns (n_poses, 256) array."""
        _, encoder = matrix_and_encoder

        protein_types = np.array([1], dtype=np.uint8)
        ligand_types = np.array([2], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0]])
        ligand_coords_list = [
            np.array([[3.0, 0.0, 0.0]]),
            np.array([[4.0, 0.0, 0.0]]),
            np.array([[100.0, 0.0, 0.0]]),  # beyond cutoff
        ]

        acts = encoder.encode_ensemble(
            protein_types, ligand_types, protein_coords, ligand_coords_list
        )
        assert acts.shape == (3, 256)
        assert acts.dtype == np.float32
        # First two poses have contacts, third does not
        assert acts[0, 1] > 0
        assert acts[1, 1] > 0
        assert np.all(acts[2] == 0.0)
        # Closer pose has stronger activation
        assert acts[0, 1] > acts[1, 1]

    def test_multiple_contacts(self, matrix_and_encoder):
        """Multiple protein-ligand atom pairs contribute."""
        m, _ = matrix_and_encoder
        from shannon_contact.pose_encoder import PoseEncoder

        m.set(3, 4, 2.0)
        m.set(4, 3, 2.0)
        encoder = PoseEncoder(m, cutoff=6.0, sigma=2.0)

        protein_types = np.array([1, 3], dtype=np.uint8)
        ligand_types = np.array([2, 4], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0], [5.0, 0.0, 0.0]])
        ligand_coords = np.array([[3.0, 0.0, 0.0], [5.0, 3.0, 0.0]])

        act = encoder.encode_pose(
            protein_types, ligand_types, protein_coords, ligand_coords
        )
        # Should have activation on types 1, 2, 3, 4
        assert act[1] > 0 or act[2] > 0
        assert act[3] > 0 or act[4] > 0


# ─── Entropy Bridge ─────────────────────────────────────────────────────────


class TestEntropyBridge:
    def test_activation_entropy_uniform(self):
        """Uniform activation has high entropy."""
        from shannon_contact.entropy_bridge import ContactEntropyAnalyzer

        m = SoftContactMatrix()
        analyzer = ContactEntropyAnalyzer(m)

        # Uniform activation over 16 bins
        activation = np.zeros(256, dtype=np.float64)
        activation[:16] = 1.0

        entropy = analyzer.activation_entropy(activation)
        assert entropy > 0

    def test_activation_entropy_peaked(self):
        """Peaked activation has lower entropy than uniform."""
        from shannon_contact.entropy_bridge import ContactEntropyAnalyzer

        m = SoftContactMatrix()
        analyzer = ContactEntropyAnalyzer(m)

        uniform = np.zeros(256, dtype=np.float64)
        uniform[:16] = 1.0

        peaked = np.zeros(256, dtype=np.float64)
        peaked[0] = 16.0  # all mass in one bin

        entropy_uniform = analyzer.activation_entropy(uniform)
        entropy_peaked = analyzer.activation_entropy(peaked)
        assert entropy_peaked < entropy_uniform

    def test_activation_entropy_zero(self):
        """Zero activation returns 0 entropy."""
        from shannon_contact.entropy_bridge import ContactEntropyAnalyzer

        m = SoftContactMatrix()
        analyzer = ContactEntropyAnalyzer(m)

        activation = np.zeros(256, dtype=np.float64)
        assert analyzer.activation_entropy(activation) == 0.0

    def test_ensemble_entropy(self):
        """ensemble_entropy returns expected keys."""
        from shannon_contact.entropy_bridge import ContactEntropyAnalyzer

        m = SoftContactMatrix()
        m.set(1, 2, 5.0)
        m.set(2, 1, 5.0)
        analyzer = ContactEntropyAnalyzer(m, cutoff=6.0, sigma=2.0)

        protein_types = np.array([1], dtype=np.uint8)
        ligand_types = np.array([2], dtype=np.uint8)
        protein_coords = np.array([[0.0, 0.0, 0.0]])
        ligand_coords_list = [
            np.array([[3.0, 0.0, 0.0]]),
            np.array([[4.0, 0.0, 0.0]]),
        ]

        result = analyzer.ensemble_entropy(
            protein_types, ligand_types, protein_coords, ligand_coords_list
        )
        assert "activations" in result
        assert "entropies" in result
        assert "mean_entropy" in result
        assert "std_entropy" in result
        assert "min_entropy" in result
        assert "entropy_range" in result
        assert "mean_activation" in result
        assert "active_types" in result
        assert result["activations"].shape == (2, 256)
        assert len(result["entropies"]) == 2


# ─── Backend ─────────────────────────────────────────────────────────────────


class TestBackend:
    def test_backend_is_string(self):
        backend = get_backend()
        assert backend in ("cpp", "numpy")
