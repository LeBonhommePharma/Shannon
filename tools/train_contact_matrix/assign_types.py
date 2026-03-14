#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Step 1: Assign 256-types to all atoms in PDBbind refined set.
# Reads mol2/SDF ligand files and PDB protein files, outputs a
# JSON-lines file of (pdb_id, atom_index, atom_type_256) records.

"""Assign 8-bit atom types to PDBbind refined set structures."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Iterator, Tuple

import numpy as np
from rdkit import Chem
from rdkit.Chem import AllChem

from shannon_contact.atom_typer import AtomTyper

logger = logging.getLogger(__name__)


def iter_pdbbind_complexes(
    pdbbind_dir: Path,
) -> Iterator[Tuple[str, Path, Path]]:
    """Iterate over PDBbind refined set complexes.

    Expected directory layout:
        pdbbind_dir/
            1a1e/
                1a1e_protein.pdb
                1a1e_ligand.mol2
            1a28/
                ...

    Yields:
        (pdb_id, protein_path, ligand_path)
    """
    for entry in sorted(pdbbind_dir.iterdir()):
        if not entry.is_dir():
            continue
        pdb_id = entry.name
        protein_pdb = entry / f"{pdb_id}_protein.pdb"
        ligand_mol2 = entry / f"{pdb_id}_ligand.mol2"
        ligand_sdf = entry / f"{pdb_id}_ligand.sdf"

        if not protein_pdb.exists():
            logger.warning(f"Skipping {pdb_id}: no protein PDB")
            continue

        if ligand_mol2.exists():
            yield pdb_id, protein_pdb, ligand_mol2
        elif ligand_sdf.exists():
            yield pdb_id, protein_pdb, ligand_sdf
        else:
            logger.warning(f"Skipping {pdb_id}: no ligand file")


def load_protein(path: Path) -> Chem.Mol | None:
    """Load protein from PDB file."""
    mol = Chem.MolFromPDBFile(str(path), removeHs=False, sanitize=False)
    if mol is not None:
        try:
            Chem.SanitizeMol(mol)
        except Exception:
            pass  # Partial sanitization is acceptable for proteins
    return mol


def load_ligand(path: Path) -> Chem.Mol | None:
    """Load ligand from mol2 or SDF file."""
    suffix = path.suffix.lower()
    if suffix == ".mol2":
        return Chem.MolFromMol2File(str(path), removeHs=False)
    elif suffix == ".sdf":
        supplier = Chem.SDMolSupplier(str(path), removeHs=False)
        return next(iter(supplier), None)
    return None


def get_coordinates(mol: Chem.Mol) -> np.ndarray | None:
    """Extract 3D coordinates from an RDKit mol."""
    conf = mol.GetConformer()
    if conf is None:
        return None
    return np.array(
        [conf.GetAtomPosition(i) for i in range(mol.GetNumAtoms())],
        dtype=np.float64,
    )


def main():
    parser = argparse.ArgumentParser(
        description="Assign 256-types to PDBbind structures."
    )
    parser.add_argument(
        "pdbbind_dir",
        type=Path,
        help="Path to PDBbind refined set directory.",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=Path("typed_atoms.jsonl"),
        help="Output JSONL file (default: typed_atoms.jsonl).",
    )
    parser.add_argument(
        "--charge-method",
        default="gasteiger",
        help="Charge computation method (default: gasteiger).",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    typer = AtomTyper(charge_method=args.charge_method)
    n_complexes = 0
    n_failed = 0

    with open(args.output, "w") as out:
        for pdb_id, protein_path, ligand_path in iter_pdbbind_complexes(
            args.pdbbind_dir
        ):
            try:
                protein_mol = load_protein(protein_path)
                ligand_mol = load_ligand(ligand_path)

                if protein_mol is None or ligand_mol is None:
                    logger.warning(f"{pdb_id}: failed to load molecules")
                    n_failed += 1
                    continue

                protein_types = typer.assign_types(protein_mol)
                ligand_types = typer.assign_types(ligand_mol)

                protein_coords = get_coordinates(protein_mol)
                ligand_coords = get_coordinates(ligand_mol)

                if protein_coords is None or ligand_coords is None:
                    logger.warning(f"{pdb_id}: missing 3D coordinates")
                    n_failed += 1
                    continue

                record = {
                    "pdb_id": pdb_id,
                    "protein_types": protein_types.tolist(),
                    "ligand_types": ligand_types.tolist(),
                    "protein_coords": protein_coords.tolist(),
                    "ligand_coords": ligand_coords.tolist(),
                }
                out.write(json.dumps(record) + "\n")
                n_complexes += 1

                if n_complexes % 100 == 0:
                    logger.info(f"Processed {n_complexes} complexes")

            except Exception as e:
                logger.error(f"{pdb_id}: {e}")
                n_failed += 1

    logger.info(
        f"Done. {n_complexes} complexes typed, {n_failed} failed. "
        f"Output: {args.output}"
    )


if __name__ == "__main__":
    main()
