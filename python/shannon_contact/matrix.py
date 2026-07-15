# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Python wrapper for the 256×256 soft contact matrix.
# Uses C++ backend when available, falls back to pure numpy.

from __future__ import annotations

import struct
from pathlib import Path
from typing import Optional, Sequence, Tuple

import numpy as np

# ── Backend selection ────────────────────────────────────────────────────────

_USE_CPP = False
try:
    import _shannon_contact_cpp as _cpp
    _USE_CPP = True
except ImportError:
    _cpp = None

NUM_ATOM_TYPES = 256
MATRIX_SIZE = NUM_ATOM_TYPES * NUM_ATOM_TYPES  # 65536
MATRIX_BYTES = MATRIX_SIZE * 4  # 262144 bytes (float32)

SCM_MAGIC = b"SCM1"
SCM_HEADER_SIZE = 16  # 4 magic + 4 version + 8 reserved
SC01_MAGIC = b"SC01"
SC01_HEADER_SIZE = 8  # 4 magic + uint16 rows + uint16 cols
FLEXAIDDS_SHNN_MAGIC = b"SHNN"
ATOM_TYPE_SCHEMA_ID = "shannon.contact.atom256.v1.base32.charge4.hbond1"
FLEXAIDDS_ATOM_TYPE_SCHEMA_ID = "flexaidds.atom256.v1.base64.charge2.hbond1"


def get_backend() -> str:
    """Return the active backend name: 'cpp' or 'numpy'."""
    return "cpp" if _USE_CPP else "numpy"


class SoftContactMatrix:
    """256×256 precomputed interaction energy lookup table.

    Each axis indexes an 8-bit atom type encoding:
      bits 0-4: base atom type (element + hybridization)
      bits 5-6: partial charge bin (4 levels)
      bit 7:    H-bond donor/acceptor flag

    The matrix stores float32 interaction energies. Lookup is O(1).
    """

    def __init__(
        self,
        path: Optional[str | Path] = None,
        data: Optional[np.ndarray] = None,
    ):
        """Initialize a soft contact matrix.

        Args:
            path: Load matrix from file. Takes precedence over ``data``.
                  Accepts raw 256 KB blobs or files with SCM1 header.
            data: Numpy array of shape (256, 256) or flat (65536,).
                  Ignored if ``path`` is provided.

        If both ``path`` and ``data`` are None, creates a zero matrix.
        """
        if _USE_CPP:
            self._cpp = _cpp.SoftContactMatrix()
            if path is not None:
                self._cpp.load(str(path))
            elif data is not None:
                self._cpp.load_from_numpy(
                    np.asarray(data, dtype=np.float32).ravel()
                )
            self._data = None
        else:
            self._cpp = None
            if path is not None:
                self._data = self._load_numpy(path)
            elif data is not None:
                self._data = np.asarray(data, dtype=np.float32).reshape(
                    NUM_ATOM_TYPES, NUM_ATOM_TYPES
                )
            else:
                self._data = np.zeros(
                    (NUM_ATOM_TYPES, NUM_ATOM_TYPES), dtype=np.float32
                )

    # ── O(1) Lookup ──────────────────────────────────────────────────────────

    def lookup(self, type_i: int, type_j: int) -> float:
        """O(1) interaction energy lookup."""
        if self._cpp is not None:
            return self._cpp.lookup(type_i, type_j)
        return float(self._data[type_i, type_j])

    def set(self, type_i: int, type_j: int, value: float) -> None:
        """Set a matrix entry."""
        if self._cpp is not None:
            self._cpp.set(type_i, type_j, value)
        else:
            self._data[type_i, type_j] = value

    # ── Bulk Operations ──────────────────────────────────────────────────────

    def to_numpy(self) -> np.ndarray:
        """Return the matrix as a (256, 256) float32 numpy array."""
        if self._cpp is not None:
            return self._cpp.to_numpy()
        return self._data.copy()

    def symmetrize(self) -> None:
        """Enforce symmetry: M[i][j] = M[j][i] = average."""
        if self._cpp is not None:
            self._cpp.symmetrize()
        else:
            self._data = (self._data + self._data.T) / 2.0

    def is_symmetric(self, tol: float = 1e-6) -> bool:
        """Check if the matrix is symmetric within tolerance."""
        if self._cpp is not None:
            return self._cpp.is_symmetric(tol)
        return bool(np.allclose(self._data, self._data.T, atol=tol))

    # ── Contact Scoring ──────────────────────────────────────────────────────

    def score_contacts(
        self,
        types_i: np.ndarray,
        types_j: np.ndarray,
        weights: Optional[np.ndarray] = None,
    ) -> float:
        """Score a set of atom-atom contacts.

        Args:
            types_i: Array of uint8 atom types (first atom in each pair)
            types_j: Array of uint8 atom types (second atom in each pair)
            weights: Optional distance-dependent weights (default 1.0)

        Returns:
            Total interaction energy.
        """
        types_i = np.asarray(types_i, dtype=np.uint8)
        types_j = np.asarray(types_j, dtype=np.uint8)
        if weights is None:
            weights = np.ones(len(types_i), dtype=np.float32)
        else:
            weights = np.asarray(weights, dtype=np.float32)

        if self._cpp is not None:
            return self._cpp.score_contacts_np(
                np.ascontiguousarray(types_i),
                np.ascontiguousarray(types_j),
                np.ascontiguousarray(weights),
            )

        # Numpy fallback
        arr = self._data
        energies = arr[types_i.astype(int), types_j.astype(int)]
        return float(np.sum(energies * weights))

    def project_to_superclusters(
        self,
        labels: Sequence[int],
        isolate_noise: bool = True,
    ) -> np.ndarray:
        """Project the 256x256 matrix to atom-contact cluster-pair means."""
        if len(labels) != NUM_ATOM_TYPES:
            raise ValueError("labels must contain exactly 256 entries")
        arr = self.to_numpy()
        type_to_cluster = np.full(NUM_ATOM_TYPES, -1, dtype=np.int32)
        label_to_cluster: dict[int, int] = {}
        n_clusters = 0

        for atom_type, raw_label in enumerate(labels):
            label = int(raw_label)
            if label < 0:
                if isolate_noise:
                    type_to_cluster[atom_type] = n_clusters
                    n_clusters += 1
                else:
                    type_to_cluster[atom_type] = 0
                    n_clusters = max(n_clusters, 1)
                continue
            if label not in label_to_cluster:
                label_to_cluster[label] = n_clusters
                n_clusters += 1
            type_to_cluster[atom_type] = label_to_cluster[label]

        if n_clusters == 0:
            n_clusters = 1
            type_to_cluster.fill(0)

        reduced = np.zeros((n_clusters, n_clusters), dtype=np.float32)
        counts = np.zeros((n_clusters, n_clusters), dtype=np.float32)
        for type_i in range(NUM_ATOM_TYPES):
            ci = type_to_cluster[type_i]
            for type_j in range(NUM_ATOM_TYPES):
                cj = type_to_cluster[type_j]
                reduced[ci, cj] += arr[type_i, type_j]
                counts[ci, cj] += 1.0
        mask = counts > 0
        reduced[mask] /= counts[mask]
        return reduced

    def pose_activation(
        self,
        types_i: np.ndarray,
        types_j: np.ndarray,
        weights: Optional[np.ndarray] = None,
    ) -> np.ndarray:
        """Compute a 256-dimensional pose activation vector.

        For each atom type t, sums the weighted matrix contributions
        from all contacts involving that type. This vector serves as
        the interface to the Shannon entropy layer.

        Returns:
            Float32 array of shape (256,).
        """
        types_i = np.asarray(types_i, dtype=np.uint8)
        types_j = np.asarray(types_j, dtype=np.uint8)
        if weights is None:
            weights = np.ones(len(types_i), dtype=np.float32)
        else:
            weights = np.asarray(weights, dtype=np.float32)

        if self._cpp is not None:
            return self._cpp.pose_activation_np(
                np.ascontiguousarray(types_i),
                np.ascontiguousarray(types_j),
                np.ascontiguousarray(weights),
            )

        # Numpy fallback
        activation = np.zeros(NUM_ATOM_TYPES, dtype=np.float32)
        arr = self._data
        for ti, tj, w in zip(types_i, types_j, weights):
            val = arr[int(ti), int(tj)] * w
            activation[int(ti)] += val
            activation[int(tj)] += val
        return activation

    # ── File I/O ─────────────────────────────────────────────────────────────

    def save(self, path: str | Path) -> None:
        """Save matrix to a binary file with SCM1 header."""
        if self._cpp is not None:
            self._cpp.save(str(path))
            return

        with open(path, "wb") as f:
            f.write(SCM_MAGIC)
            f.write(struct.pack("<I", 1))  # version
            f.write(struct.pack("<Q", 0))  # reserved
            f.write(self._data.tobytes())

    def load(self, path: str | Path) -> None:
        """Load matrix from a binary file (raw or with SCM1 header)."""
        if self._cpp is not None:
            self._cpp.load(str(path))
            return
        self._data = self._load_numpy(path)

    @staticmethod
    def _load_numpy(path: str | Path) -> np.ndarray:
        """Load matrix data into a numpy array."""
        raw = Path(path).read_bytes()

        if raw[:4] == FLEXAIDDS_SHNN_MAGIC and len(raw) == 12 + MATRIX_BYTES:
            raise ValueError(
                "Cannot load FlexAIDdS SHNN matrix into Shannon: atom type "
                f"schema mismatch ({FLEXAIDDS_ATOM_TYPE_SCHEMA_ID} != "
                f"{ATOM_TYPE_SCHEMA_ID})"
            )

        if len(raw) == SCM_HEADER_SIZE + MATRIX_BYTES:
            # Has SCM1 header
            if raw[:4] != SCM_MAGIC:
                raise ValueError(f"Invalid magic bytes in {path}")
            raw = raw[SCM_HEADER_SIZE:]
        elif len(raw) == SC01_HEADER_SIZE + MATRIX_BYTES:
            if raw[:4] != SC01_MAGIC:
                raise ValueError(f"Invalid magic bytes in {path}")
            rows, cols = struct.unpack("<HH", raw[4:8])
            if rows != NUM_ATOM_TYPES or cols != NUM_ATOM_TYPES:
                raise ValueError(
                    f"Invalid SC01 dimensions {rows}x{cols}; expected 256x256"
                )
            raw = raw[SC01_HEADER_SIZE:]
        elif len(raw) != MATRIX_BYTES:
            raise ValueError(
                f"Unexpected file size {len(raw)} for {path} "
                f"(expected {MATRIX_BYTES}, {SCM_HEADER_SIZE + MATRIX_BYTES}, "
                f"or {SC01_HEADER_SIZE + MATRIX_BYTES})"
            )

        return np.frombuffer(raw, dtype=np.float32).reshape(
            NUM_ATOM_TYPES, NUM_ATOM_TYPES
        ).copy()
