#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Step 2: Accumulate pairwise contact statistics from typed atoms.
# For every protein-ligand atom pair within the 12 Å cutoff across
# all training complexes, records (type_i, type_j, distance, ΔG_exp).

"""Accumulate pairwise contact statistics for matrix training."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from typing import Optional

import numpy as np
from scipy.spatial import cKDTree

logger = logging.getLogger(__name__)

# Contact cutoff in angstroms
DEFAULT_CUTOFF = 12.0


def load_binding_data(index_file: Path) -> dict[str, float]:
    """Load experimental binding affinities from PDBbind index.

    Expected format (tab-separated):
        PDB_ID  resolution  release_year  -logKd/Ki  Kd/Ki  reference  ligand_name

    Returns:
        dict mapping pdb_id -> -log(Kd/Ki) in kcal/mol proxy units.
    """
    binding_data = {}
    with open(index_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 4:
                pdb_id = parts[0].lower()
                try:
                    affinity = float(parts[3])
                    binding_data[pdb_id] = affinity
                except ValueError:
                    continue
    return binding_data


def enumerate_contacts(
    protein_coords: np.ndarray,
    ligand_coords: np.ndarray,
    protein_types: np.ndarray,
    ligand_types: np.ndarray,
    cutoff: float = DEFAULT_CUTOFF,
) -> list[tuple[int, int, float]]:
    """Find all protein-ligand atom pairs within cutoff using KD-tree.

    Returns:
        List of (type_i, type_j, distance) tuples.
    """
    tree = cKDTree(protein_coords)
    contacts = []

    for lig_idx, lig_coord in enumerate(ligand_coords):
        neighbors = tree.query_ball_point(lig_coord, cutoff)
        for prot_idx in neighbors:
            dist = np.linalg.norm(protein_coords[prot_idx] - lig_coord)
            contacts.append((
                int(protein_types[prot_idx]),
                int(ligand_types[lig_idx]),
                float(dist),
            ))

    return contacts


def main():
    parser = argparse.ArgumentParser(
        description="Accumulate pairwise contact statistics."
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
        help="PDBbind index file with experimental binding affinities.",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=Path("contact_stats.npz"),
        help="Output .npz file (default: contact_stats.npz).",
    )
    parser.add_argument(
        "--cutoff",
        type=float,
        default=DEFAULT_CUTOFF,
        help=f"Contact cutoff in angstroms (default: {DEFAULT_CUTOFF}).",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    # Load binding data
    binding_data = load_binding_data(args.index)
    logger.info(f"Loaded {len(binding_data)} binding affinities")

    # Accumulate contacts
    # For each (type_i, type_j) cell: list of (distance, affinity) pairs
    cell_contacts: dict[tuple[int, int], list[tuple[float, float]]] = {}
    n_complexes = 0
    n_total_contacts = 0

    with open(args.typed_atoms) as f:
        for line in f:
            record = json.loads(line)
            pdb_id = record["pdb_id"].lower()

            if pdb_id not in binding_data:
                logger.debug(f"{pdb_id}: no binding affinity, skipping")
                continue

            affinity = binding_data[pdb_id]
            protein_types = np.array(record["protein_types"], dtype=np.uint8)
            ligand_types = np.array(record["ligand_types"], dtype=np.uint8)
            protein_coords = np.array(record["protein_coords"], dtype=np.float64)
            ligand_coords = np.array(record["ligand_coords"], dtype=np.float64)

            contacts = enumerate_contacts(
                protein_coords, ligand_coords,
                protein_types, ligand_types,
                cutoff=args.cutoff,
            )

            for type_i, type_j, dist in contacts:
                key = (type_i, type_j)
                if key not in cell_contacts:
                    cell_contacts[key] = []
                cell_contacts[key].append((dist, affinity))

            n_total_contacts += len(contacts)
            n_complexes += 1

            if n_complexes % 100 == 0:
                logger.info(
                    f"Processed {n_complexes} complexes, "
                    f"{n_total_contacts} total contacts"
                )

    # Save contact statistics
    # Convert to arrays for each cell
    cell_keys = []
    cell_distances = []
    cell_affinities = []
    cell_counts = []

    for (ti, tj), pairs in sorted(cell_contacts.items()):
        cell_keys.append([ti, tj])
        dists = [p[0] for p in pairs]
        affs = [p[1] for p in pairs]
        cell_distances.append(dists)
        cell_affinities.append(affs)
        cell_counts.append(len(pairs))

    # Save as compressed numpy archive
    np.savez_compressed(
        args.output,
        cell_keys=np.array(cell_keys, dtype=np.uint8),
        cell_counts=np.array(cell_counts, dtype=np.int64),
        # Variable-length arrays stored as object arrays
        n_cells=len(cell_keys),
        n_complexes=n_complexes,
        n_total_contacts=n_total_contacts,
        cutoff=args.cutoff,
    )

    # Also save the raw contact data as a separate JSONL for the fitter
    raw_output = args.output.with_suffix(".contacts.jsonl")
    with open(raw_output, "w") as f:
        for (ti, tj), pairs in sorted(cell_contacts.items()):
            record = {
                "type_i": int(ti),
                "type_j": int(tj),
                "distances": [p[0] for p in pairs],
                "affinities": [p[1] for p in pairs],
            }
            f.write(json.dumps(record) + "\n")

    logger.info(
        f"Done. {n_complexes} complexes, {n_total_contacts} contacts, "
        f"{len(cell_keys)} unique type pairs. "
        f"Output: {args.output}, {raw_output}"
    )


if __name__ == "__main__":
    main()
