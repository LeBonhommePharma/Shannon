# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Entropy bridge: connects the 256×256 soft contact matrix to the
# Shannon entropy layer for super-cluster detection in docking.

from __future__ import annotations

from typing import List, Optional

import numpy as np

from shannon_contact.matrix import SoftContactMatrix, NUM_ATOM_TYPES
from shannon_contact.pose_encoder import PoseEncoder
from shannon import shannon_configurational_entropy


class ContactEntropyAnalyzer:
    """Compute Shannon entropy over contact matrix activation space.

    When you dock a ligand and generate 10³–10⁴ low-energy poses, each
    pose activates a specific subset of the 256×256 matrix cells. As
    poses converge toward a dominant binding mode:

    1. The active cell pattern converges (fewer diverse contacts).
    2. The 256-dim activation vectors cluster.
    3. Shannon entropy over the activation distribution drops sharply.

    This class detects that entropy collapse in matrix space — the
    "super-cluster" formation that indicates convergent binding.
    """

    def __init__(
        self,
        matrix: SoftContactMatrix,
        cutoff: float = 12.0,
        sigma: float = 3.0,
    ):
        """Initialize the analyzer.

        Args:
            matrix: The 256×256 soft contact matrix.
            cutoff: Distance cutoff in angstroms.
            sigma: Gaussian decay parameter for contact weighting.
        """
        self.matrix = matrix
        self.encoder = PoseEncoder(matrix, cutoff=cutoff, sigma=sigma)

    def activation_entropy(self, activation: np.ndarray) -> float:
        """Compute Shannon entropy of a single pose's activation vector.

        The 256-dim activation vector is normalized to a probability
        distribution, then its entropy is computed. Low entropy means
        the pose's contacts are concentrated in a few type-pair bins.

        Args:
            activation: Float array of shape (256,).

        Returns:
            Entropy in bits.
        """
        activation = np.asarray(activation, dtype=np.float64)
        total = activation.sum()
        if total <= 0:
            return 0.0

        # Normalize to probability distribution
        probs = activation / total
        # Filter zeros and compute log-weights for configurational entropy
        mask = probs > 1e-300
        log_weights = np.full_like(probs, -700.0)  # ~log(1e-300)
        log_weights[mask] = np.log(probs[mask])

        return float(shannon_configurational_entropy(log_weights))

    def ensemble_entropy(
        self,
        protein_types: np.ndarray,
        ligand_types: np.ndarray,
        protein_coords: np.ndarray,
        ligand_coords_list: list[np.ndarray],
    ) -> dict:
        """Analyze entropy collapse across a pose ensemble.

        Encodes each pose as a 256-dim activation vector, computes
        per-pose entropy, and detects super-cluster formation.

        Args:
            protein_types: uint8 atom types for protein atoms.
            ligand_types: uint8 atom types for ligand atoms.
            protein_coords: Protein coordinates, shape (n_prot, 3).
            ligand_coords_list: List of ligand coordinate arrays.

        Returns:
            Dictionary with:
              - 'activations': (n_poses, 256) array
              - 'entropies': per-pose entropy values
              - 'mean_entropy': mean across ensemble
              - 'std_entropy': standard deviation
              - 'min_entropy': minimum (most converged pose)
              - 'entropy_range': max - min
              - 'mean_activation': (256,) mean activation profile
              - 'active_types': number of non-zero activation bins
        """
        activations = self.encoder.encode_ensemble(
            protein_types, ligand_types, protein_coords, ligand_coords_list
        )

        entropies = np.array([
            self.activation_entropy(act) for act in activations
        ])

        mean_activation = activations.mean(axis=0)
        active_types = int(np.sum(mean_activation > 1e-6))

        return {
            "activations": activations,
            "entropies": entropies,
            "mean_entropy": float(entropies.mean()),
            "std_entropy": float(entropies.std()),
            "min_entropy": float(entropies.min()),
            "entropy_range": float(entropies.max() - entropies.min()),
            "mean_activation": mean_activation,
            "active_types": active_types,
        }

    def detect_supercluster(
        self,
        activations: np.ndarray,
        n_clusters_max: int = 10,
    ) -> dict:
        """Detect super-cluster formation in activation space.

        Uses simple k-means clustering on the 256-dim activation
        vectors to identify the dominant binding mode.

        Args:
            activations: (n_poses, 256) array of activation vectors.
            n_clusters_max: Maximum number of clusters to try.

        Returns:
            Dictionary with:
              - 'labels': cluster assignment per pose
              - 'dominant_cluster': index of largest cluster
              - 'dominant_fraction': fraction of poses in dominant cluster
              - 'n_clusters': optimal number of clusters
        """
        from sklearn.cluster import KMeans

        n_poses = activations.shape[0]
        n_clusters_max = min(n_clusters_max, n_poses)

        best_score = -np.inf
        best_k = 1
        best_labels = np.zeros(n_poses, dtype=int)

        for k in range(1, n_clusters_max + 1):
            km = KMeans(n_clusters=k, n_init=5, random_state=42)
            labels = km.fit_predict(activations)
            if k == 1:
                best_labels = labels
                continue

            # Silhouette score requires k >= 2
            from sklearn.metrics import silhouette_score
            score = silhouette_score(activations, labels)
            if score > best_score:
                best_score = score
                best_k = k
                best_labels = labels

        # Find dominant cluster
        unique, counts = np.unique(best_labels, return_counts=True)
        dominant_idx = unique[np.argmax(counts)]
        dominant_fraction = float(counts.max()) / n_poses

        return {
            "labels": best_labels,
            "dominant_cluster": int(dominant_idx),
            "dominant_fraction": dominant_fraction,
            "n_clusters": best_k,
        }
