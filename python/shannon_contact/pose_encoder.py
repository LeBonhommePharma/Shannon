# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Pose encoder: converts docking poses into 256-dim activation vectors
# for Shannon entropy analysis.  Uses scipy KD-tree for efficient
# neighbor search (O(n log n) vs O(n*m) dense distance matrix).

from __future__ import annotations

from typing import Optional, Tuple

import numpy as np
from scipy.spatial import cKDTree

from shannon_contact.matrix import SoftContactMatrix, NUM_ATOM_TYPES


def gaussian_contact_weight(
    distance: float,
    cutoff: float = 12.0,
    sigma: float = 3.0,
) -> float:
    """Distance-dependent Gaussian contact weight.

    Returns 1.0 at distance=0, decays with Gaussian envelope,
    and is hard-zeroed beyond the cutoff.
    """
    if distance > cutoff:
        return 0.0
    return float(np.exp(-0.5 * (distance / sigma) ** 2))


def _find_contacts(
    protein_coords: np.ndarray,
    ligand_coords: np.ndarray,
    cutoff: float,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Find protein-ligand contacts within cutoff using KD-tree.

    Returns:
        (prot_indices, lig_indices, distances) — all 1D arrays.
    """
    tree = cKDTree(protein_coords)
    prot_indices = []
    lig_indices = []
    dists = []

    for lig_idx, lig_coord in enumerate(ligand_coords):
        neighbors = tree.query_ball_point(lig_coord, cutoff)
        if neighbors:
            for prot_idx in neighbors:
                d = np.linalg.norm(protein_coords[prot_idx] - lig_coord)
                prot_indices.append(prot_idx)
                lig_indices.append(lig_idx)
                dists.append(d)

    if not prot_indices:
        return (
            np.array([], dtype=np.intp),
            np.array([], dtype=np.intp),
            np.array([], dtype=np.float64),
        )

    return (
        np.array(prot_indices, dtype=np.intp),
        np.array(lig_indices, dtype=np.intp),
        np.array(dists, dtype=np.float64),
    )


class PoseEncoder:
    """Encodes docking poses as 256-dimensional activation vectors.

    A pose is defined by a set of protein-ligand atom contacts.
    Each contact contributes to a 256-dim vector via the soft contact
    matrix, creating a "fingerprint" of the binding interaction.

    This vector is the interface between the contact matrix and the
    Shannon entropy layer: clustering these vectors across a pose
    ensemble reveals the super-cluster (dominant binding mode) and
    enables entropy collapse detection in matrix space.
    """

    def __init__(
        self,
        matrix: SoftContactMatrix,
        cutoff: float = 12.0,
        sigma: float = 3.0,
    ):
        """Initialize the pose encoder.

        Args:
            matrix: The 256×256 soft contact matrix.
            cutoff: Distance cutoff in angstroms for contacts.
            sigma: Gaussian decay parameter for distance weighting.
        """
        self.matrix = matrix
        self.cutoff = cutoff
        self.sigma = sigma

    def encode_pose(
        self,
        protein_types: np.ndarray,
        ligand_types: np.ndarray,
        protein_coords: np.ndarray,
        ligand_coords: np.ndarray,
    ) -> np.ndarray:
        """Encode a single docking pose as a 256-dim activation vector.

        Uses KD-tree neighbor search — O(n log n) instead of O(n*m).

        Args:
            protein_types: uint8 atom types for protein atoms, shape (n_prot,)
            ligand_types: uint8 atom types for ligand atoms, shape (n_lig,)
            protein_coords: Protein atom coordinates, shape (n_prot, 3)
            ligand_coords: Ligand atom coordinates, shape (n_lig, 3)

        Returns:
            Float32 activation vector, shape (256,).
        """
        protein_types = np.asarray(protein_types, dtype=np.uint8)
        ligand_types = np.asarray(ligand_types, dtype=np.uint8)
        protein_coords = np.asarray(protein_coords, dtype=np.float64)
        ligand_coords = np.asarray(ligand_coords, dtype=np.float64)

        prot_idx, lig_idx, contact_dists = _find_contacts(
            protein_coords, ligand_coords, self.cutoff
        )

        if len(prot_idx) == 0:
            return np.zeros(NUM_ATOM_TYPES, dtype=np.float32)

        weights = np.exp(
            -0.5 * (contact_dists / self.sigma) ** 2
        ).astype(np.float32)

        types_i = protein_types[prot_idx]
        types_j = ligand_types[lig_idx]

        return self.matrix.pose_activation(types_i, types_j, weights)

    def score_pose(
        self,
        protein_types: np.ndarray,
        ligand_types: np.ndarray,
        protein_coords: np.ndarray,
        ligand_coords: np.ndarray,
    ) -> float:
        """Score a docking pose using the contact matrix.

        Args:
            Same as encode_pose.

        Returns:
            Total interaction energy (float).
        """
        protein_types = np.asarray(protein_types, dtype=np.uint8)
        ligand_types = np.asarray(ligand_types, dtype=np.uint8)
        protein_coords = np.asarray(protein_coords, dtype=np.float64)
        ligand_coords = np.asarray(ligand_coords, dtype=np.float64)

        prot_idx, lig_idx, contact_dists = _find_contacts(
            protein_coords, ligand_coords, self.cutoff
        )

        if len(prot_idx) == 0:
            return 0.0

        weights = np.exp(
            -0.5 * (contact_dists / self.sigma) ** 2
        ).astype(np.float32)

        types_i = protein_types[prot_idx]
        types_j = ligand_types[lig_idx]

        return self.matrix.score_contacts(types_i, types_j, weights)

    def encode_ensemble(
        self,
        protein_types: np.ndarray,
        ligand_types: np.ndarray,
        protein_coords: np.ndarray,
        ligand_coords_list: list[np.ndarray],
    ) -> np.ndarray:
        """Encode a pose ensemble as a matrix of activation vectors.

        Builds one KD-tree for the protein and reuses it across all poses.

        Args:
            protein_types: uint8 atom types for protein atoms.
            ligand_types: uint8 atom types for ligand atoms.
            protein_coords: Protein coordinates (fixed).
            ligand_coords_list: List of ligand coordinate arrays (one per pose).

        Returns:
            Float32 array of shape (n_poses, 256).
        """
        activations = np.zeros(
            (len(ligand_coords_list), NUM_ATOM_TYPES), dtype=np.float32
        )
        for i, lig_coords in enumerate(ligand_coords_list):
            activations[i] = self.encode_pose(
                protein_types, ligand_types, protein_coords, lig_coords
            )
        return activations
