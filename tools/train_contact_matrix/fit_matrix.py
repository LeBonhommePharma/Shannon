#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Step 3: Fit the 256×256 soft contact matrix.
#
# Pipeline:
#   Phase 1: Per-cell ridge regression (linear, fast initialization)
#   Phase 2: L-BFGS nonlinear refinement against CASF-2016 Pearson r
#
# The distance function f(r) is a Gaussian contact weight:
#   f(r) = exp(-0.5 * (r/sigma)^2)
#
# For each complex:
#   ΔG_predicted = Σ_{contacts} matrix[type_i][type_j] * f(r_ij)
#
# We optimize the matrix entries to minimize RMSE between
# ΔG_predicted and ΔG_experimental.

"""Fit the 256×256 soft contact matrix from contact statistics."""

from __future__ import annotations

import argparse
import json
import logging
import struct
from pathlib import Path

import numpy as np
from scipy.optimize import minimize
from scipy.sparse import csr_matrix
from sklearn.linear_model import Ridge

logger = logging.getLogger(__name__)

NUM_TYPES = 256
MATRIX_SIZE = NUM_TYPES * NUM_TYPES
SCM_MAGIC = b"SCM1"
DEFAULT_SIGMA = 3.0


def gaussian_weight(distance: float, sigma: float = DEFAULT_SIGMA) -> float:
    """Gaussian contact weight function."""
    return np.exp(-0.5 * (distance / sigma) ** 2)


def load_contacts_and_affinities(
    typed_atoms_path: Path,
    binding_index_path: Path,
    cutoff: float = 12.0,
    sigma: float = DEFAULT_SIGMA,
) -> tuple[np.ndarray, np.ndarray]:
    """Load typed complexes and build the design matrix.

    Returns:
        X: Sparse design matrix, shape (n_complexes, 65536)
            Each row is the weighted contact fingerprint of a complex.
        y: Experimental binding affinities, shape (n_complexes,)
    """
    from accumulate_contacts import (
        load_binding_data,
        enumerate_contacts,
    )

    binding_data = load_binding_data(binding_index_path)

    rows_data = []  # (complex_idx, cell_idx, weight) triples
    y_list = []
    complex_idx = 0

    with open(typed_atoms_path) as f:
        for line in f:
            record = json.loads(line)
            pdb_id = record["pdb_id"].lower()

            if pdb_id not in binding_data:
                continue

            affinity = binding_data[pdb_id]
            protein_types = np.array(record["protein_types"], dtype=np.uint8)
            ligand_types = np.array(record["ligand_types"], dtype=np.uint8)
            protein_coords = np.array(record["protein_coords"], dtype=np.float64)
            ligand_coords = np.array(record["ligand_coords"], dtype=np.float64)

            contacts = enumerate_contacts(
                protein_coords, ligand_coords,
                protein_types, ligand_types,
                cutoff=cutoff,
            )

            if not contacts:
                continue

            # Build fingerprint for this complex
            fingerprint: dict[int, float] = {}
            for type_i, type_j, dist in contacts:
                cell_idx = type_i * NUM_TYPES + type_j
                w = gaussian_weight(dist, sigma)
                fingerprint[cell_idx] = fingerprint.get(cell_idx, 0.0) + w

            for cell_idx, weight in fingerprint.items():
                rows_data.append((complex_idx, cell_idx, weight))

            y_list.append(affinity)
            complex_idx += 1

    if not y_list:
        raise ValueError("No complexes with binding data found")

    # Build sparse design matrix
    row_indices = [r[0] for r in rows_data]
    col_indices = [r[1] for r in rows_data]
    values = [r[2] for r in rows_data]

    X = csr_matrix(
        (values, (row_indices, col_indices)),
        shape=(len(y_list), MATRIX_SIZE),
        dtype=np.float64,
    )
    y = np.array(y_list, dtype=np.float64)

    return X, y


def phase1_ridge(
    X: np.ndarray,
    y: np.ndarray,
    alpha: float = 1.0,
) -> np.ndarray:
    """Phase 1: Per-cell ridge regression.

    Linear fit: y = X @ matrix_flat + noise.
    Returns the flattened 65536-element matrix.
    """
    logger.info(f"Phase 1: Ridge regression (alpha={alpha})")
    model = Ridge(alpha=alpha, fit_intercept=True)
    model.fit(X, y)

    y_pred = model.predict(X)
    rmse = np.sqrt(np.mean((y - y_pred) ** 2))
    pearson = np.corrcoef(y, y_pred)[0, 1]
    logger.info(f"  Ridge RMSE: {rmse:.3f}, Pearson r: {pearson:.3f}")

    return model.coef_.astype(np.float32)


def phase2_lbfgs(
    X: np.ndarray,
    y: np.ndarray,
    matrix_init: np.ndarray,
    max_iter: int = 200,
) -> np.ndarray:
    """Phase 2: L-BFGS nonlinear refinement.

    Optimizes Pearson correlation between predicted and experimental
    binding affinities.
    """
    logger.info(f"Phase 2: L-BFGS refinement (max_iter={max_iter})")

    # Only optimize cells that have non-zero contacts
    active_mask = np.array(X.sum(axis=0)).ravel() > 0
    active_indices = np.where(active_mask)[0]
    n_active = len(active_indices)
    logger.info(f"  Active cells: {n_active} / {MATRIX_SIZE}")

    x0 = matrix_init[active_indices].astype(np.float64)

    def objective(params):
        full_matrix = np.zeros(MATRIX_SIZE, dtype=np.float64)
        full_matrix[active_indices] = params
        y_pred = X @ full_matrix
        # Negative Pearson r (we minimize)
        if np.std(y_pred) < 1e-10:
            return 1.0  # Degenerate case
        r = np.corrcoef(y, y_pred)[0, 1]
        return -r

    result = minimize(
        objective,
        x0,
        method="L-BFGS-B",
        options={"maxiter": max_iter, "disp": False},
    )

    logger.info(
        f"  L-BFGS converged: {result.success}, "
        f"final -r: {result.fun:.4f}, iters: {result.nit}"
    )

    final_matrix = np.zeros(MATRIX_SIZE, dtype=np.float32)
    final_matrix[active_indices] = result.x.astype(np.float32)
    return final_matrix


def symmetrize_matrix(matrix: np.ndarray) -> np.ndarray:
    """Enforce symmetry on the flattened matrix."""
    m = matrix.reshape(NUM_TYPES, NUM_TYPES)
    m = (m + m.T) / 2.0
    return m.ravel()


def save_matrix(matrix: np.ndarray, path: Path) -> None:
    """Save matrix as binary blob with SCM1 header."""
    matrix = matrix.astype(np.float32)
    with open(path, "wb") as f:
        f.write(SCM_MAGIC)
        f.write(struct.pack("<I", 1))  # version
        f.write(struct.pack("<Q", 0))  # reserved
        f.write(matrix.tobytes())
    logger.info(f"Saved matrix to {path} ({path.stat().st_size} bytes)")


def project_to_40x40(
    matrix_256: np.ndarray,
    n_sybyl: int = 32,
) -> np.ndarray:
    """Project 256×256 matrix to coarse SYBYL-parent resolution.

    Each cell in the reduced matrix is the mean of the corresponding
    block in the 256×256, grouped by base type (bits 0-4).

    This validates that the 256×256 is consistent with FlexAID's
    coarser representation.
    """
    m = matrix_256.reshape(NUM_TYPES, NUM_TYPES)
    reduced = np.zeros((n_sybyl, n_sybyl), dtype=np.float32)
    counts = np.zeros((n_sybyl, n_sybyl), dtype=np.int32)

    for i in range(NUM_TYPES):
        base_i = i & 0x1F
        for j in range(NUM_TYPES):
            base_j = j & 0x1F
            if base_i < n_sybyl and base_j < n_sybyl:
                reduced[base_i, base_j] += m[i, j]
                counts[base_i, base_j] += 1

    mask = counts > 0
    reduced[mask] /= counts[mask]
    return reduced


def main():
    parser = argparse.ArgumentParser(
        description="Fit the 256×256 soft contact matrix."
    )
    parser.add_argument(
        "typed_atoms",
        type=Path,
        help="JSONL file from assign_types.py.",
    )
    parser.add_argument(
        "-i", "--index",
        type=Path,
        required=True,
        help="PDBbind index file with binding affinities.",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=Path("soft_contact_256x256.bin"),
        help="Output binary matrix (default: soft_contact_256x256.bin).",
    )
    parser.add_argument(
        "--cutoff",
        type=float,
        default=12.0,
        help="Contact cutoff in angstroms (default: 12.0).",
    )
    parser.add_argument(
        "--sigma",
        type=float,
        default=DEFAULT_SIGMA,
        help=f"Gaussian sigma (default: {DEFAULT_SIGMA}).",
    )
    parser.add_argument(
        "--ridge-alpha",
        type=float,
        default=1.0,
        help="Ridge regression alpha (default: 1.0).",
    )
    parser.add_argument(
        "--lbfgs-maxiter",
        type=int,
        default=200,
        help="L-BFGS max iterations (default: 200).",
    )
    parser.add_argument(
        "--skip-lbfgs",
        action="store_true",
        help="Skip L-BFGS refinement (ridge only).",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    # Build design matrix
    logger.info("Loading contacts and building design matrix...")
    X, y = load_contacts_and_affinities(
        args.typed_atoms, args.index,
        cutoff=args.cutoff, sigma=args.sigma,
    )
    logger.info(f"Design matrix: {X.shape[0]} complexes, {X.nnz} non-zero entries")

    # Phase 1: Ridge regression
    matrix = phase1_ridge(X, y, alpha=args.ridge_alpha)

    # Phase 2: L-BFGS refinement
    if not args.skip_lbfgs:
        matrix = phase2_lbfgs(X, y, matrix, max_iter=args.lbfgs_maxiter)

    # Symmetrize
    matrix = symmetrize_matrix(matrix)

    # Save
    save_matrix(matrix, args.output)

    # Validate: project to 32×32 (SYBYL parent resolution)
    reduced = project_to_40x40(matrix)
    logger.info(f"32×32 projection: {np.count_nonzero(reduced)} non-zero cells")

    # Final stats
    m = matrix.reshape(NUM_TYPES, NUM_TYPES)
    logger.info(
        f"Matrix stats: min={m.min():.4f}, max={m.max():.4f}, "
        f"mean={m.mean():.4f}, non-zero={np.count_nonzero(m)}"
    )


if __name__ == "__main__":
    main()
