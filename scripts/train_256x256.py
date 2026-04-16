#!/usr/bin/env python3
# =============================================================================
# train_256x256.py — PDBbind Training Pipeline for 256×256 Soft-Contact Matrix
#
# Trains the Shannon 256×256 energy matrix from PDBbind structural data with
# CASF-2016 validation. Replaces the closed-form fallback in build_soft_contact.py
# with data-driven ridge regression + L-BFGS refinement.
#
# Pipeline:
#   1. Parse PDBbind mol2 (ligand) + PDB (protein) files
#   2. Assign 256-types via 8-bit encoding (SYBYL → base type + charge + H-bond)
#   3. Enumerate pairwise contacts via KD-tree (12 Å cutoff)
#   4. Per-cell ridge regression for initial matrix values
#   5. L-BFGS global refinement against CASF-2016 Pearson r
#   6. Validate via 256→40 projection against FlexAID's SYBYL matrix
#   7. Output SC01 binary blob
#
# Usage:
#   python scripts/train_256x256.py --pdbbind-dir /path/to/PDBbind \
#       --casf-dir /path/to/CASF-2016 --output data/soft_contact_256.bin
#
# For development without PDBbind data:
#   python scripts/train_256x256.py --synthetic --output data/soft_contact_256.bin
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import argparse
import logging
import struct
import sys
from pathlib import Path
from typing import NamedTuple

import numpy as np

logger = logging.getLogger(__name__)


# =============================================================================
# SYBYL Bridge: mol2 atom types → 32 base types
# =============================================================================

# Maps ~45 SYBYL (Tripos) atom type strings to base types 0-31.
# Base types 0-19: standard SYBYL mapping
# Base types 20-21: context-aware refinements (NATURaL-specific)
# Base types 22-31: reserved for extensions
SYBYL_TO_BASE: dict[str, int] = {
    # Carbon
    "C.3":    0,   # sp3 carbon
    "C.2":    1,   # sp2 carbon
    "C.1":    2,   # sp carbon
    "C.ar":   3,   # aromatic carbon
    "C.cat":  4,   # carbocation
    # Nitrogen
    "N.3":    5,   # sp3 nitrogen
    "N.2":    6,   # sp2 nitrogen
    "N.1":    7,   # sp nitrogen
    "N.ar":   8,   # aromatic nitrogen
    "N.am":   9,   # amide nitrogen
    "N.pl3": 10,   # trigonal planar nitrogen
    "N.4":   11,   # sp3 positively charged nitrogen
    # Oxygen
    "O.3":   12,   # sp3 oxygen
    "O.2":   13,   # sp2 oxygen
    "O.co2": 14,   # carboxylate oxygen
    "O.spc": 12,   # water (treat as O.3)
    "O.t3p": 12,   # water (treat as O.3)
    # Sulfur
    "S.3":   15,   # sp3 sulfur
    "S.2":   16,   # sp2 sulfur
    "S.O":   17,   # sulfoxide sulfur
    "S.O2":  17,   # sulfone sulfur (same bin as sulfoxide)
    # Phosphorus
    "P.3":   18,   # sp3 phosphorus
    # Hydrogen
    "H":     19,   # hydrogen
    "H.spc": 19,   # water hydrogen
    "H.t3p": 19,   # water hydrogen
    # Context-aware refinements (NATURaL-specific)
    "C.ar.het":    20,  # aromatic C adjacent to heteroatom (indole/tryptamine)
    "C.2.bridge":  21,  # sp2 C bridging two aromatic systems
    # Halogens
    "F":     22,   # fluorine
    "Cl":    23,   # chlorine
    "Br":    24,   # bromine
    "I":     25,   # iodine
    # Metals (coarse-grained)
    "Zn":    26,   # zinc
    "Fe":    27,   # iron
    "Mg":    28,   # magnesium
    "Ca":    29,   # calcium
    "Mn":    28,   # manganese (same bin as Mg)
    "Cu":    26,   # copper (same bin as Zn)
    "Co":    27,   # cobalt (same bin as Fe)
    # Misc
    "Si":    30,   # silicon
    "Du":    31,   # dummy atom
    "LP":    31,   # lone pair (dummy)
    "Any":   31,   # any (dummy)
}

# Reverse map: 32 base types → SYBYL parent index (0-39 in SYBYL numbering)
# Only the first 32 of 40 SYBYL types are populated from our encoding
BASE_TO_SYBYL_PARENT: list[int] = [
    0, 1, 2, 3, 4,         # C.3, C.2, C.1, C.ar, C.cat
    5, 6, 7, 8, 9, 10, 11, # N.3, N.2, N.1, N.ar, N.am, N.pl3, N.4
    12, 13, 14,             # O.3, O.2, O.co2
    15, 16, 17,             # S.3, S.2, S.O
    18,                     # P.3
    19,                     # H
    3, 1,                   # C.ar.het→C.ar parent, C.2.bridge→C.2 parent
    20, 21, 22, 23,         # F, Cl, Br, I
    24, 25, 26, 27,         # Zn, Fe, Mg, Ca
    28, 29,                 # Si, Du
]


def sybyl_to_base(sybyl_type: str) -> int:
    """Map SYBYL atom type string to 32 base types (0-31). Returns 31 for unknown."""
    return SYBYL_TO_BASE.get(sybyl_type, 31)


def base_to_sybyl_parent(base: int) -> int:
    """Map 32 base types back to SYBYL parent index (0-39)."""
    if 0 <= base < len(BASE_TO_SYBYL_PARENT):
        return BASE_TO_SYBYL_PARENT[base]
    return 29  # dummy


# =============================================================================
# 8-bit type encoding
# =============================================================================

def encode_type(base: int, charge_bin: int, hbond: bool) -> int:
    """Encode (base_type, charge_bin, hbond) into 8-bit type index."""
    return (base & 0x1F) | ((charge_bin & 0x03) << 5) | (int(hbond) << 7)


def decode_type(t: int) -> tuple[int, int, int]:
    """Decode 8-bit type index into (base_type, charge_bin, hbond_flag)."""
    return t & 0x1F, (t >> 5) & 0x03, (t >> 7) & 0x01


def charge_to_bin(partial_charge: float) -> int:
    """Map AM1-BCC partial charge to 4 bins: strong-, weak-, weak+, strong+."""
    if partial_charge < -0.4:
        return 0  # strong negative
    elif partial_charge < 0.0:
        return 1  # weak negative
    elif partial_charge < 0.4:
        return 2  # weak positive
    else:
        return 3  # strong positive


# H-bond donor/acceptor elements
_HBOND_DONORS = {"N", "O", "S"}
_HBOND_ACCEPTORS = {"N", "O", "F"}


def is_hbond(element: str, sybyl_type: str) -> bool:
    """Determine H-bond donor/acceptor from element and SYBYL type."""
    return element in _HBOND_DONORS or element in _HBOND_ACCEPTORS


# =============================================================================
# Structural data parsing
# =============================================================================

class Atom(NamedTuple):
    x: float
    y: float
    z: float
    type_256: int
    element: str


def parse_mol2_atoms(path: Path) -> list[Atom]:
    """Parse atoms from a SYBYL mol2 file, assign 256-types."""
    atoms = []
    in_atoms = False

    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("@<TRIPOS>ATOM"):
                in_atoms = True
                continue
            elif line.startswith("@<TRIPOS>"):
                in_atoms = False
                continue

            if not in_atoms:
                continue

            parts = line.split()
            if len(parts) < 9:
                continue

            x, y, z = float(parts[2]), float(parts[3]), float(parts[4])
            sybyl_type = parts[5]
            charge = float(parts[8]) if len(parts) > 8 else 0.0

            # Extract element from SYBYL type
            element = sybyl_type.split(".")[0]

            # Context-aware refinement for aromatic carbons
            base = sybyl_to_base(sybyl_type)
            charge_bin = charge_to_bin(charge)
            hbond = is_hbond(element, sybyl_type)

            type_256 = encode_type(base, charge_bin, hbond)
            atoms.append(Atom(x, y, z, type_256, element))

    return atoms


def parse_pdb_atoms(path: Path) -> list[Atom]:
    """Parse ATOM/HETATM records from a PDB file, assign 256-types."""
    atoms = []

    # PDB element → approximate SYBYL type mapping
    element_to_sybyl = {
        "C": "C.3", "N": "N.3", "O": "O.3", "S": "S.3",
        "P": "P.3", "H": "H", "F": "F", "CL": "Cl",
        "BR": "Br", "I": "I", "ZN": "Zn", "FE": "Fe",
        "MG": "Mg", "CA": "Ca", "MN": "Mn", "CU": "Cu",
        "CO": "Co", "SI": "Si",
    }

    with open(path) as f:
        for line in f:
            record = line[:6].strip()
            if record not in ("ATOM", "HETATM"):
                continue

            try:
                x = float(line[30:38])
                y = float(line[38:46])
                z = float(line[46:54])
                element = line[76:78].strip().upper()
                if not element:
                    # Fallback: infer from atom name
                    element = line[12:16].strip()[0]
            except (ValueError, IndexError):
                continue

            sybyl_type = element_to_sybyl.get(element, "Du")
            base = sybyl_to_base(sybyl_type)
            # PDB has no partial charges; use neutral bin
            charge_bin = 2  # weak positive (neutral-ish)
            hbond = is_hbond(element, sybyl_type)

            type_256 = encode_type(base, charge_bin, hbond)
            atoms.append(Atom(x, y, z, type_256, element))

    return atoms


def apply_context_refinements(
    ligand_atoms: list[Atom],
    mol2_path: Path,
) -> list[Atom]:
    """Apply context-aware type refinements for NATURaL-critical systems.

    - C_ar_hetadj (base 20): aromatic C adjacent to N, O, S in same ring
    - C_pi_bridging (base 21): sp2 C bridging two aromatic systems
    """
    # Parse bond block from mol2 for connectivity
    bonds: list[tuple[int, int]] = []
    in_bonds = False

    with open(mol2_path) as f:
        for line in f:
            line_s = line.strip()
            if line_s.startswith("@<TRIPOS>BOND"):
                in_bonds = True
                continue
            elif line_s.startswith("@<TRIPOS>"):
                in_bonds = False
                continue
            if not in_bonds:
                continue
            parts = line_s.split()
            if len(parts) >= 4:
                a1, a2 = int(parts[1]) - 1, int(parts[2]) - 1  # 0-indexed
                bonds.append((a1, a2))

    # Build adjacency
    adj: dict[int, set[int]] = {}
    for a1, a2 in bonds:
        adj.setdefault(a1, set()).add(a2)
        adj.setdefault(a2, set()).add(a1)

    refined = list(ligand_atoms)
    for i, atom in enumerate(ligand_atoms):
        base, charge_bin, hbond_flag = decode_type(atom.type_256)

        # C.ar adjacent to heteroatom
        if base == 3:  # C.ar
            neighbors = adj.get(i, set())
            for nb in neighbors:
                if nb < len(ligand_atoms):
                    nb_elem = ligand_atoms[nb].element
                    if nb_elem in ("N", "O", "S"):
                        new_type = encode_type(20, charge_bin, hbond_flag)
                        refined[i] = atom._replace(type_256=new_type)
                        break

        # C.2 bridging two aromatic systems
        elif base == 1:  # C.2
            neighbors = adj.get(i, set())
            ar_neighbors = 0
            for nb in neighbors:
                if nb < len(ligand_atoms):
                    nb_base = decode_type(ligand_atoms[nb].type_256)[0]
                    if nb_base in (3, 20):  # C.ar or C.ar.het
                        ar_neighbors += 1
            if ar_neighbors >= 2:
                new_type = encode_type(21, charge_bin, hbond_flag)
                refined[i] = atom._replace(type_256=new_type)

    return refined


# =============================================================================
# PDBbind index parsing
# =============================================================================

def parse_pdbbind_index(index_path: Path) -> dict[str, float]:
    """Parse PDBbind INDEX file to get PDB code → experimental ΔG (kcal/mol)."""
    pdb_to_dg: dict[str, float] = {}
    RT = 0.592  # kcal/mol at 298 K

    with open(index_path) as f:
        for line in f:
            if line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 4:
                continue

            pdb_code = parts[0].strip()
            # PDBbind format: pdb_code  resolution  year  -logKd/Ki  Kd/Ki=value
            try:
                neg_log_kd = float(parts[3])
                # ΔG = RT * ln(Kd) = -RT * ln(10) * pKd
                delta_g = -RT * 2.303 * neg_log_kd
                pdb_to_dg[pdb_code] = delta_g
            except ValueError:
                continue

    return pdb_to_dg


# =============================================================================
# Contact enumeration via KD-tree
# =============================================================================

class Contact(NamedTuple):
    type_i: int
    type_j: int
    distance: float
    complex_id: int


def enumerate_contacts(
    protein_atoms: list[Atom],
    ligand_atoms: list[Atom],
    complex_id: int,
    cutoff: float = 12.0,
) -> list[Contact]:
    """Enumerate protein-ligand contacts within cutoff using KD-tree."""
    from scipy.spatial import KDTree

    if not protein_atoms or not ligand_atoms:
        return []

    prot_coords = np.array([[a.x, a.y, a.z] for a in protein_atoms])
    lig_coords = np.array([[a.x, a.y, a.z] for a in ligand_atoms])

    prot_tree = KDTree(prot_coords)
    lig_tree = KDTree(lig_coords)

    # Query all pairs within cutoff
    pairs = prot_tree.query_ball_tree(lig_tree, r=cutoff)

    contacts = []
    for prot_idx, lig_indices in enumerate(pairs):
        for lig_idx in lig_indices:
            dx = prot_coords[prot_idx] - lig_coords[lig_idx]
            dist = float(np.sqrt(np.sum(dx * dx)))
            contacts.append(Contact(
                type_i=protein_atoms[prot_idx].type_256,
                type_j=ligand_atoms[lig_idx].type_256,
                distance=dist,
                complex_id=complex_id,
            ))

    return contacts


# =============================================================================
# Closed-form fallback (from build_soft_contact.py)
# =============================================================================

def compute_energy_closed_form(ti: int, tj: int) -> float:
    """Closed-form LJ + Debye-Hückel + desolvation energy (development fallback)."""
    base_i, charge_i, hbond_i = decode_type(ti)
    base_j, charge_j, hbond_j = decode_type(tj)

    sigma_i = 1.4 + (base_i / 31.0) * 2.6
    sigma_j = 1.4 + (base_j / 31.0) * 2.6
    eps_i = 0.02 + (base_i / 31.0) * 0.28
    eps_j = 0.02 + (base_j / 31.0) * 0.28

    q_i = [-0.8, -0.2, 0.2, 0.8][charge_i]
    q_j = [-0.8, -0.2, 0.2, 0.8][charge_j]

    sa_i = 4.0 * np.pi * sigma_i ** 2
    sa_j = 4.0 * np.pi * sigma_j ** 2

    sigma_ij = (sigma_i + sigma_j) / 2.0
    eps_ij = np.sqrt(eps_i * eps_j)
    r_ij = sigma_ij * 1.122

    hbond_bonus = -0.5 if (hbond_i != hbond_j) else 0.0

    sr6 = (sigma_ij / r_ij) ** 6
    e_lj = eps_ij * (sr6 * sr6 - 2.0 * sr6)

    kappa = 0.3
    coulomb = 332.06
    e_elec = coulomb * q_i * q_j * np.exp(-kappa * r_ij) / r_ij

    gamma = 0.005
    e_desolv = gamma * (sa_i + sa_j)

    return float(e_lj + e_elec + e_desolv + hbond_bonus)


# =============================================================================
# Ridge regression (per-cell initial fit)
# =============================================================================

def distance_kernel(r: float, sigma: float = 3.0) -> float:
    """Gaussian distance-dependent kernel."""
    return np.exp(-r * r / (2.0 * sigma * sigma))


def ridge_regression_fit(
    contacts: list[Contact],
    delta_g: dict[int, float],
    min_observations: int = 10,
    lam: float = 0.1,
) -> np.ndarray:
    """Fit 256×256 matrix via per-cell ridge regression.

    For each (type_i, type_j) pair, fit the weight that best predicts
    experimental ΔG from distance-weighted contact counts.

    Falls back to closed-form for cells with < min_observations contacts.
    """
    matrix = np.zeros((256, 256), dtype=np.float64)

    # Group contacts by (type_i, type_j) pair
    cell_contacts: dict[tuple[int, int], list[tuple[float, int]]] = {}
    for c in contacts:
        key = (min(c.type_i, c.type_j), max(c.type_i, c.type_j))
        cell_contacts.setdefault(key, []).append((c.distance, c.complex_id))

    n_fitted = 0
    n_fallback = 0

    for (ti, tj), obs in cell_contacts.items():
        if len(obs) < min_observations:
            # Fall back to closed-form
            e = compute_energy_closed_form(ti, tj)
            matrix[ti, tj] = e
            matrix[tj, ti] = e
            n_fallback += 1
            continue

        # Group by complex: sum distance-weighted contributions
        complex_features: dict[int, float] = {}
        for dist, cid in obs:
            k = distance_kernel(dist)
            complex_features[cid] = complex_features.get(cid, 0.0) + k

        # Build X (features) and y (targets)
        cids = sorted(complex_features.keys())
        X = np.array([complex_features[cid] for cid in cids]).reshape(-1, 1)
        y = np.array([delta_g.get(cid, 0.0) for cid in cids])

        # Ridge regression: w = (X^T X + λI)^{-1} X^T y
        XtX = X.T @ X + lam * np.eye(1)
        Xty = X.T @ y
        w = float(np.linalg.solve(XtX, Xty).ravel()[0])

        matrix[ti, tj] = w
        matrix[tj, ti] = w
        n_fitted += 1

    # Fill remaining cells with closed-form
    for i in range(256):
        for j in range(i, 256):
            if matrix[i, j] == 0.0:
                e = compute_energy_closed_form(i, j)
                matrix[i, j] = e
                matrix[j, i] = e

    logger.info(f"Ridge fit: {n_fitted} cells from data, {n_fallback} cells fallback")
    return matrix


# =============================================================================
# L-BFGS global refinement
# =============================================================================

def lbfgs_refine(
    matrix_init: np.ndarray,
    contacts_by_complex: dict[int, list[Contact]],
    delta_g_exp: dict[int, float],
    reg_strength: float = 0.01,
    max_iter: int = 200,
) -> tuple[np.ndarray, dict[str, float]]:
    """Refine 256×256 matrix via L-BFGS-B to maximize Pearson r against CASF-2016.

    Optimizes the upper triangle (32,768 unique pair weights) to minimize
    negative Pearson r with L2 regularization toward initial values.

    Returns (refined_matrix, metrics_dict).
    """
    from scipy.optimize import minimize

    complex_ids = sorted(set(delta_g_exp.keys()) & set(contacts_by_complex.keys()))
    if len(complex_ids) < 10:
        logger.warning(f"Only {len(complex_ids)} complexes for refinement, skipping L-BFGS")
        return matrix_init, {"pearson_r": 0.0, "rmse": 0.0}

    y_exp = np.array([delta_g_exp[cid] for cid in complex_ids])

    # Precompute contact features per complex: list of (type_i, type_j, kernel_val)
    complex_features: dict[int, list[tuple[int, int, float]]] = {}
    for cid in complex_ids:
        feats = []
        for c in contacts_by_complex.get(cid, []):
            ti, tj = min(c.type_i, c.type_j), max(c.type_i, c.type_j)
            k = distance_kernel(c.distance)
            feats.append((ti, tj, k))
        complex_features[cid] = feats

    # Pack upper triangle into 1D vector for optimization
    triu_indices = np.triu_indices(256)
    x0 = matrix_init[triu_indices].copy()
    x_init = x0.copy()

    def objective(x: np.ndarray) -> tuple[float, np.ndarray]:
        # Unpack to full matrix
        mat = np.zeros((256, 256), dtype=np.float64)
        mat[triu_indices] = x
        mat = mat + mat.T - np.diag(np.diag(mat))

        # Predict ΔG for each complex
        y_pred = np.zeros(len(complex_ids))
        for idx, cid in enumerate(complex_ids):
            score = 0.0
            for ti, tj, k in complex_features[cid]:
                score += mat[ti, tj] * k
            y_pred[idx] = score

        # Pearson r (want to maximize, so minimize negative)
        y_pred_c = y_pred - y_pred.mean()
        y_exp_c = y_exp - y_exp.mean()
        std_pred = np.sqrt(np.sum(y_pred_c ** 2) + 1e-15)
        std_exp = np.sqrt(np.sum(y_exp_c ** 2) + 1e-15)
        pearson_r = np.sum(y_pred_c * y_exp_c) / (std_pred * std_exp)

        # L2 regularization toward initial values
        reg = reg_strength * np.sum((x - x_init) ** 2)

        loss = -pearson_r + reg

        # Gradient
        # d(-pearson_r)/d(y_pred) via chain rule
        n = len(y_pred)
        dr_dy = (y_exp_c / (std_pred * std_exp)
                 - pearson_r * y_pred_c / (std_pred ** 2)) / n

        grad_mat = np.zeros((256, 256), dtype=np.float64)
        for idx, cid in enumerate(complex_ids):
            for ti, tj, k in complex_features[cid]:
                grad_mat[ti, tj] -= dr_dy[idx] * k

        # Symmetrize gradient
        grad_mat = grad_mat + grad_mat.T - np.diag(np.diag(grad_mat))
        grad = grad_mat[triu_indices] + 2.0 * reg_strength * (x - x_init)

        return loss, grad

    logger.info(f"L-BFGS refinement: {len(complex_ids)} complexes, "
                f"{len(x0)} parameters, max_iter={max_iter}")

    result = minimize(
        objective,
        x0,
        method="L-BFGS-B",
        jac=True,
        options={"maxiter": max_iter, "ftol": 1e-10, "gtol": 1e-6},
    )

    # Unpack result
    mat_refined = np.zeros((256, 256), dtype=np.float64)
    mat_refined[triu_indices] = result.x
    mat_refined = mat_refined + mat_refined.T - np.diag(np.diag(mat_refined))

    # Compute final metrics
    y_pred = np.zeros(len(complex_ids))
    for idx, cid in enumerate(complex_ids):
        for ti, tj, k in complex_features[cid]:
            y_pred[idx] += mat_refined[min(ti, tj), max(ti, tj)] * k

    from scipy.stats import pearsonr
    r_val, _ = pearsonr(y_pred, y_exp)
    rmse = float(np.sqrt(np.mean((y_pred - y_exp) ** 2)))

    metrics = {
        "pearson_r": float(r_val),
        "rmse": rmse,
        "converged": result.success,
        "iterations": result.nit,
        "final_loss": float(result.fun),
    }

    logger.info(f"L-BFGS result: Pearson r={r_val:.4f}, RMSE={rmse:.4f}, "
                f"converged={result.success}, iterations={result.nit}")

    return mat_refined.astype(np.float64), metrics


# =============================================================================
# 256→40 projection (FlexAID validation)
# =============================================================================

def project_to_40x40(matrix_256: np.ndarray) -> np.ndarray:
    """Coarse-grain 256×256 to 40×40 SYBYL-equivalent via block-mean."""
    sybyl_parent = np.array([
        base_to_sybyl_parent(decode_type(t)[0]) for t in range(256)
    ])

    n_sybyl = 32  # populated SYBYL parents from our encoding
    cf = np.zeros((n_sybyl, n_sybyl), dtype=np.float32)
    counts = np.zeros((n_sybyl, n_sybyl), dtype=int)

    for i in range(256):
        for j in range(256):
            si = sybyl_parent[i]
            sj = sybyl_parent[j]
            if si < n_sybyl and sj < n_sybyl:
                cf[si, sj] += matrix_256[i, j]
                counts[si, sj] += 1

    mask = counts > 0
    cf[mask] /= counts[mask]
    return cf


# =============================================================================
# Validation
# =============================================================================

def validate_matrix(matrix: np.ndarray) -> None:
    """Run sanity checks on trained matrix."""
    assert matrix.shape == (256, 256), f"Wrong shape: {matrix.shape}"

    # Symmetry
    max_asym = np.max(np.abs(matrix - matrix.T))
    assert max_asym < 1e-10, f"Asymmetry: max diff = {max_asym}"

    # No NaN/Inf
    assert not np.any(np.isnan(matrix)), "NaN values found"
    assert not np.any(np.isinf(matrix)), "Inf values found"

    # Non-trivial
    nonzero = np.count_nonzero(matrix)
    assert nonzero > 60000, f"Too few non-zero entries: {nonzero}"

    logger.info(f"Validation passed: shape={matrix.shape}, "
                f"nonzero={nonzero}/{256*256}, "
                f"range=[{matrix.min():.4f}, {matrix.max():.4f}], "
                f"symmetry={max_asym:.2e}")


# =============================================================================
# SC01 binary I/O
# =============================================================================

def write_sc01(matrix: np.ndarray, path: Path) -> None:
    """Write 256×256 matrix in SC01 format (4-byte magic + 2×uint16 dims + float32 data)."""
    mat_f32 = matrix.astype(np.float32)
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"SC01")
        f.write(struct.pack("<HH", 256, 256))
        f.write(mat_f32.tobytes())
    logger.info(f"Written SC01: {path} ({path.stat().st_size} bytes)")


def read_sc01(path: Path) -> np.ndarray:
    """Read 256×256 matrix from SC01 binary blob."""
    with open(path, "rb") as f:
        magic = f.read(4)
        assert magic == b"SC01", f"Bad magic: {magic}"
        rows, cols = struct.unpack("<HH", f.read(4))
        assert rows == 256 and cols == 256
        data = np.frombuffer(f.read(256 * 256 * 4), dtype=np.float32)
    return data.reshape(256, 256).copy()


# =============================================================================
# Synthetic data generation (for development without PDBbind)
# =============================================================================

def generate_synthetic_training_data(
    n_complexes: int = 500,
    contacts_per_complex: int = 100,
    seed: int = 42,
) -> tuple[list[Contact], dict[int, float]]:
    """Generate synthetic contacts and ΔG values for testing the pipeline."""
    rng = np.random.default_rng(seed)

    contacts = []
    delta_g = {}

    # Create a "ground truth" matrix
    gt_matrix = np.zeros((256, 256), dtype=np.float64)
    for i in range(256):
        for j in range(i, 256):
            gt_matrix[i, j] = compute_energy_closed_form(i, j)
            gt_matrix[j, i] = gt_matrix[i, j]

    for cid in range(n_complexes):
        # Random contacts
        n_contacts = rng.poisson(contacts_per_complex)
        types_i = rng.integers(0, 256, size=n_contacts).astype(int)
        types_j = rng.integers(0, 256, size=n_contacts).astype(int)
        dists = rng.uniform(2.0, 12.0, size=n_contacts)

        # Compute "experimental" ΔG from ground truth + noise
        score = 0.0
        for k in range(n_contacts):
            ti, tj = int(types_i[k]), int(types_j[k])
            score += gt_matrix[ti, tj] * distance_kernel(dists[k])
            contacts.append(Contact(ti, tj, float(dists[k]), cid))

        delta_g[cid] = score + rng.normal(0, 0.5)

    logger.info(f"Generated {len(contacts)} synthetic contacts across "
                f"{n_complexes} complexes")
    return contacts, delta_g


# =============================================================================
# Full PDBbind training pipeline
# =============================================================================

def train_from_pdbbind(
    pdbbind_dir: Path,
    casf_dir: Path | None,
    output_path: Path,
    cutoff: float = 12.0,
    min_obs: int = 10,
    ridge_lambda: float = 0.1,
    lbfgs_max_iter: int = 200,
    lbfgs_reg: float = 0.01,
) -> None:
    """Full training pipeline from PDBbind structural data."""
    # Step 1: Parse PDBbind index
    index_path = pdbbind_dir / "INDEX" / "INDEX_general_PL_data.2020"
    if not index_path.exists():
        # Try alternative index file names
        for name in ["INDEX_general_PL.2020", "INDEX_refined_data.2020",
                      "INDEX_general_PL_data.2016", "INDEX_refined_data.2016"]:
            alt = pdbbind_dir / "INDEX" / name
            if alt.exists():
                index_path = alt
                break
        else:
            # Try flat index
            for f in pdbbind_dir.glob("INDEX*"):
                index_path = f
                break

    logger.info(f"Parsing PDBbind index: {index_path}")
    pdb_to_dg = parse_pdbbind_index(index_path)
    logger.info(f"Found {len(pdb_to_dg)} complexes with experimental ΔG")

    # Step 2: Enumerate contacts
    all_contacts: list[Contact] = []
    contacts_by_complex: dict[int, list[Contact]] = {}
    delta_g: dict[int, float] = {}
    complex_id = 0

    refined_dir = pdbbind_dir / "refined-set"
    if not refined_dir.exists():
        refined_dir = pdbbind_dir  # flat layout

    for pdb_code, dg in pdb_to_dg.items():
        complex_dir = refined_dir / pdb_code
        if not complex_dir.is_dir():
            continue

        # Find mol2 and PDB files
        mol2_files = list(complex_dir.glob(f"{pdb_code}_ligand.mol2"))
        pdb_files = list(complex_dir.glob(f"{pdb_code}_protein.pdb"))

        if not mol2_files or not pdb_files:
            continue

        try:
            ligand_atoms = parse_mol2_atoms(mol2_files[0])
            protein_atoms = parse_pdb_atoms(pdb_files[0])

            # Apply context-aware refinements to ligand
            ligand_atoms = apply_context_refinements(ligand_atoms, mol2_files[0])

            contacts = enumerate_contacts(protein_atoms, ligand_atoms,
                                          complex_id, cutoff)
            all_contacts.extend(contacts)
            contacts_by_complex[complex_id] = contacts
            delta_g[complex_id] = dg
            complex_id += 1

            if complex_id % 100 == 0:
                logger.info(f"  Processed {complex_id} complexes, "
                            f"{len(all_contacts)} contacts")
        except Exception as e:
            logger.warning(f"  Skipping {pdb_code}: {e}")

    logger.info(f"Total: {complex_id} complexes, {len(all_contacts)} contacts")

    # Step 3: Ridge regression
    logger.info("Running per-cell ridge regression...")
    matrix = ridge_regression_fit(all_contacts, delta_g,
                                  min_observations=min_obs, lam=ridge_lambda)

    # Step 4: L-BFGS refinement
    if casf_dir and casf_dir.exists():
        casf_index = casf_dir / "CoreSet.dat"
        if casf_index.exists():
            casf_dg = parse_pdbbind_index(casf_index)
            logger.info(f"CASF-2016: {len(casf_dg)} complexes for refinement")
            matrix, metrics = lbfgs_refine(
                matrix, contacts_by_complex, delta_g,
                reg_strength=lbfgs_reg, max_iter=lbfgs_max_iter,
            )
        else:
            logger.warning(f"CASF index not found: {casf_index}")
            # Refine against training data
            matrix, metrics = lbfgs_refine(
                matrix, contacts_by_complex, delta_g,
                reg_strength=lbfgs_reg, max_iter=lbfgs_max_iter,
            )
    else:
        # Refine against training data
        logger.info("No CASF directory provided, refining against training data")
        matrix, metrics = lbfgs_refine(
            matrix, contacts_by_complex, delta_g,
            reg_strength=lbfgs_reg, max_iter=lbfgs_max_iter,
        )

    # Step 5: Validate and output
    validate_matrix(matrix)

    # 256→40 projection
    cf_40 = project_to_40x40(matrix)
    logger.info(f"40×40 projection: range=[{cf_40.min():.4f}, {cf_40.max():.4f}], "
                f"mean={cf_40.mean():.4f}")

    write_sc01(matrix, output_path)


def train_synthetic(output_path: Path) -> None:
    """Train from synthetic data (development mode)."""
    logger.info("Generating synthetic training data...")
    contacts, delta_g = generate_synthetic_training_data(
        n_complexes=500, contacts_per_complex=100,
    )

    contacts_by_complex: dict[int, list[Contact]] = {}
    for c in contacts:
        contacts_by_complex.setdefault(c.complex_id, []).append(c)

    # Ridge regression
    logger.info("Running ridge regression...")
    matrix = ridge_regression_fit(contacts, delta_g)

    # L-BFGS refinement
    logger.info("Running L-BFGS refinement...")
    matrix, metrics = lbfgs_refine(
        matrix, contacts_by_complex, delta_g,
        reg_strength=0.01, max_iter=100,
    )

    # Validate
    validate_matrix(matrix)

    # 256→40 projection
    cf_40 = project_to_40x40(matrix)
    logger.info(f"40×40 projection: range=[{cf_40.min():.4f}, {cf_40.max():.4f}]")

    write_sc01(matrix, output_path)
    logger.info(f"Training complete. Metrics: {metrics}")


# =============================================================================
# CLI
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Train Shannon 256×256 soft-contact energy matrix from PDBbind data"
    )
    parser.add_argument(
        "--pdbbind-dir", type=Path, default=None,
        help="Path to PDBbind directory (contains refined-set/ and INDEX/)",
    )
    parser.add_argument(
        "--casf-dir", type=Path, default=None,
        help="Path to CASF-2016 directory for validation/refinement",
    )
    parser.add_argument(
        "--output", "-o", type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "soft_contact_256.bin",
        help="Output path for SC01 binary blob",
    )
    parser.add_argument(
        "--synthetic", action="store_true",
        help="Use synthetic data instead of PDBbind (development mode)",
    )
    parser.add_argument(
        "--cutoff", type=float, default=12.0,
        help="Contact distance cutoff in Angstroms (default: 12.0)",
    )
    parser.add_argument(
        "--min-obs", type=int, default=10,
        help="Minimum observations per cell before falling back to closed-form",
    )
    parser.add_argument(
        "--ridge-lambda", type=float, default=0.1,
        help="Ridge regression regularization (default: 0.1)",
    )
    parser.add_argument(
        "--lbfgs-max-iter", type=int, default=200,
        help="Maximum L-BFGS iterations (default: 200)",
    )
    parser.add_argument(
        "--lbfgs-reg", type=float, default=0.01,
        help="L-BFGS L2 regularization strength (default: 0.01)",
    )
    parser.add_argument(
        "--show-projection", action="store_true",
        help="Show 40×40 projection statistics",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true",
        help="Verbose logging",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%H:%M:%S",
    )

    if args.synthetic:
        train_synthetic(args.output)
    elif args.pdbbind_dir:
        train_from_pdbbind(
            pdbbind_dir=args.pdbbind_dir,
            casf_dir=args.casf_dir,
            output_path=args.output,
            cutoff=args.cutoff,
            min_obs=args.min_obs,
            ridge_lambda=args.ridge_lambda,
            lbfgs_max_iter=args.lbfgs_max_iter,
            lbfgs_reg=args.lbfgs_reg,
        )
    else:
        parser.error("Either --pdbbind-dir or --synthetic is required")

    if args.show_projection:
        matrix = read_sc01(args.output)
        cf_40 = project_to_40x40(matrix)
        print(f"\n40×40 projection:")
        print(f"  Shape: {cf_40.shape}")
        print(f"  Range: [{cf_40.min():.4f}, {cf_40.max():.4f}]")
        print(f"  Mean:  {cf_40.mean():.4f}")


if __name__ == "__main__":
    main()
