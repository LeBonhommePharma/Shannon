#!/usr/bin/env python3
# =============================================================================
# build_soft_contact.py — Generate 256x256 Soft-Contact Energy Matrix
#
# Builds the precomputed soft_contact_256.bin binary blob shipped with Shannon.
# The matrix encodes pairwise interaction energies using the 8-bit type encoding:
#
#   Bits 0-4: Base atom/concept type (element + hybridization)  [32 types]
#   Bits 5-6: Partial charge bin (strong-, weak-, weak+, strong+) [4 states]
#   Bit    7: H-bond donor/acceptor flag                         [2 states]
#
#   Total: 32 x 4 x 2 = 256 types
#
# Each E[i][j] is derived from three physical potentials:
#   - Lennard-Jones 12-6:   eps * [(sigma/r)^12 - 2(sigma/r)^6]
#   - Debye-Huckel:         q_i * q_j * exp(-kappa*r) / (4*pi*eps0*r)
#   - Desolvation:          gamma * (SA_i + SA_j)
#
# The matrix is symmetric and stored as float32 in row-major order (256 KB).
#
# For production use: replace the closed-form generation below with the
# PDBbind + CASF-2016 iterative Monte Carlo optimization pipeline from
# FlexAIDdS (see NaturalField::getSoftContact).
#
# Usage:
#   python scripts/build_soft_contact.py [--output data/soft_contact_256.bin]
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

import numpy as np


# =============================================================================
# 8-bit type encoding helpers
# =============================================================================

def decode_type(t: int) -> tuple[int, int, int]:
    """Decode 8-bit type index into (base_type, charge_bin, hbond_flag)."""
    base = t & 0x1F          # bits 0-4
    charge = (t >> 5) & 0x03  # bits 5-6
    hbond = (t >> 7) & 0x01   # bit 7
    return base, charge, hbond


def charge_value(charge_bin: int) -> float:
    """Map charge bin to effective partial charge."""
    # 0: strong-  1: weak-  2: weak+  3: strong+
    return [-0.8, -0.2, 0.2, 0.8][charge_bin]


def base_type_sigma(base: int) -> float:
    """Effective van der Waals radius for base type (Angstroms)."""
    # 32 base types: approximate as linear ramp from 1.4 A (hydrogen-like)
    # to 4.0 A (large aromatic/metal)
    return 1.4 + (base / 31.0) * 2.6


def base_type_epsilon(base: int) -> float:
    """Effective well depth for base type (kcal/mol)."""
    # Range from 0.02 (weak) to 0.30 (strong dispersion)
    return 0.02 + (base / 31.0) * 0.28


def surface_area(base: int) -> float:
    """Effective surface area proxy (A^2)."""
    sigma = base_type_sigma(base)
    return 4.0 * np.pi * sigma * sigma


# =============================================================================
# Pairwise energy computation
# =============================================================================

def compute_energy(ti: int, tj: int) -> float:
    """Compute pairwise soft-contact energy between types ti and tj."""
    base_i, charge_i, hbond_i = decode_type(ti)
    base_j, charge_j, hbond_j = decode_type(tj)

    sigma_i = base_type_sigma(base_i)
    sigma_j = base_type_sigma(base_j)
    eps_i = base_type_epsilon(base_i)
    eps_j = base_type_epsilon(base_j)

    q_i = charge_value(charge_i)
    q_j = charge_value(charge_j)

    sa_i = surface_area(base_i)
    sa_j = surface_area(base_j)

    # Combining rules (Lorentz-Berthelot)
    sigma_ij = (sigma_i + sigma_j) / 2.0
    eps_ij = np.sqrt(eps_i * eps_j)

    # Effective distance: geometric mean of radii + steric buffer
    r_ij = sigma_ij * 1.122  # equilibrium distance (2^(1/6) * sigma approx)

    # H-bond modulation: attractive bonus when donor meets acceptor
    hbond_bonus = -0.5 if (hbond_i != hbond_j) else 0.0

    # 1. Lennard-Jones 12-6
    sr6 = (sigma_ij / r_ij) ** 6
    e_lj = eps_ij * (sr6 * sr6 - 2.0 * sr6)

    # 2. Debye-Huckel screened electrostatics
    kappa = 0.3  # inverse Debye length (1/A)
    coulomb = 332.06  # kcal*A/(mol*e^2)
    e_elec = coulomb * q_i * q_j * np.exp(-kappa * r_ij) / r_ij

    # 3. Desolvation penalty
    gamma = 0.005  # kcal/(mol*A^2)
    e_desolv = gamma * (sa_i + sa_j)

    # Total
    return float(e_lj + e_elec + e_desolv + hbond_bonus)


# =============================================================================
# Matrix generation
# =============================================================================

def build_matrix() -> np.ndarray:
    """Build the full 256x256 soft-contact energy matrix."""
    matrix = np.zeros((256, 256), dtype=np.float32)

    for i in range(256):
        for j in range(i, 256):
            e = compute_energy(i, j)
            matrix[i, j] = e
            matrix[j, i] = e  # symmetric

    return matrix


def validate_matrix(matrix: np.ndarray) -> None:
    """Run basic sanity checks on the generated matrix."""
    assert matrix.shape == (256, 256), f"Wrong shape: {matrix.shape}"
    assert matrix.dtype == np.float32, f"Wrong dtype: {matrix.dtype}"

    # Symmetry
    max_asym = np.max(np.abs(matrix - matrix.T))
    assert max_asym < 1e-10, f"Asymmetry detected: max diff = {max_asym}"

    # No NaN/Inf
    assert not np.any(np.isnan(matrix)), "NaN values found"
    assert not np.any(np.isinf(matrix)), "Inf values found"

    # Non-trivial: most entries should be non-zero
    nonzero = np.count_nonzero(matrix)
    assert nonzero > 60000, f"Too few non-zero entries: {nonzero}"

    print(f"  Shape:       {matrix.shape}")
    print(f"  Dtype:       {matrix.dtype}")
    print(f"  Size:        {matrix.nbytes / 1024:.1f} KB")
    print(f"  Non-zero:    {nonzero} / {256*256}")
    print(f"  Range:       [{matrix.min():.4f}, {matrix.max():.4f}]")
    print(f"  Mean:        {matrix.mean():.4f}")
    print(f"  Symmetry:    max |M-M^T| = {max_asym:.2e}")


# =============================================================================
# 40x40 coarse-grained projection (for FlexAID comparison)
# =============================================================================

def project_to_40x40(matrix_256: np.ndarray) -> np.ndarray:
    """Coarse-grain the 256x256 matrix to 40x40 SYBYL-equivalent.

    Each 40x40 cell is the block-mean of the corresponding subtypes.
    The SYBYL parent of a 256-type is determined by the base type (bits 0-4)
    modulo 40 (since we have 32 base types, we map base -> sybyl_id).
    """
    # Map 256 types to 40 SYBYL-like parent types
    # 32 base types map to first 32 of 40; remaining 8 are unused
    sybyl_parent = np.zeros(256, dtype=int)
    for t in range(256):
        base, _, _ = decode_type(t)
        sybyl_parent[t] = base  # base type 0-31 maps directly

    n_sybyl = 32  # only 32 of 40 are populated from our encoding
    cf_40 = np.zeros((n_sybyl, n_sybyl), dtype=np.float32)
    counts = np.zeros((n_sybyl, n_sybyl), dtype=int)

    for i in range(256):
        for j in range(256):
            si = sybyl_parent[i]
            sj = sybyl_parent[j]
            cf_40[si, sj] += matrix_256[i, j]
            counts[si, sj] += 1

    # Block mean
    mask = counts > 0
    cf_40[mask] /= counts[mask]

    return cf_40


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Generate Shannon 256x256 soft-contact energy matrix"
    )
    parser.add_argument(
        "--output", "-o",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "soft_contact_256.bin",
        help="Output path for binary blob (default: data/soft_contact_256.bin)",
    )
    parser.add_argument(
        "--validate", action="store_true", default=True,
        help="Run validation checks (default: True)",
    )
    parser.add_argument(
        "--show-projection", action="store_true",
        help="Show 40x40 coarse-grained projection stats",
    )
    args = parser.parse_args()

    print("Building 256x256 soft-contact energy matrix...")
    matrix = build_matrix()

    if args.validate:
        print("Validating matrix:")
        validate_matrix(matrix)

    # Write binary blob (row-major float32)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with open(args.output, "wb") as f:
        # Header: magic bytes + version + dimensions
        f.write(b"SC01")  # magic: Soft Contact v01
        f.write(struct.pack("<HH", 256, 256))  # dimensions
        f.write(matrix.tobytes())  # row-major float32

    print(f"Written to: {args.output} ({args.output.stat().st_size} bytes)")

    if args.show_projection:
        print("\n40x40 coarse-grained projection:")
        cf_40 = project_to_40x40(matrix)
        print(f"  Shape: {cf_40.shape}")
        print(f"  Range: [{cf_40.min():.4f}, {cf_40.max():.4f}]")
        print(f"  Mean:  {cf_40.mean():.4f}")


if __name__ == "__main__":
    main()
