# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Atom type assignment for the 256×256 soft contact matrix.
# Maps RDKit molecules to 8-bit atom type indices.

from __future__ import annotations

from typing import List, Optional

import numpy as np

ATOM_TYPE_SCHEMA_ID = "shannon.contact.atom256.v1.base32.charge4.hbond1"
FLEXAIDDS_ATOM_TYPE_SCHEMA_ID = "flexaidds.atom256.v1.base64.charge2.hbond1"
ATOM_TYPE_SCHEMA_VERSION = 1

# Charge bin thresholds
_CHARGE_THRESHOLDS = (-0.25, 0.0, 0.25)


def encode_atom_type(
    base_type: int,
    charge_bin: int,
    hbond_flag: int,
) -> int:
    """Encode atom type fields into a single uint8 index.

    Args:
        base_type: Base atom type (0-31)
        charge_bin: Partial charge bin (0-3)
        hbond_flag: H-bond donor/acceptor (0 or 1)

    Returns:
        8-bit atom type index (0-255).
    """
    return (hbond_flag << 7) | ((charge_bin & 0x03) << 5) | (base_type & 0x1F)


def decode_atom_type(atom_type: int) -> tuple[int, int, int]:
    """Decode an 8-bit atom type into (base_type, charge_bin, hbond_flag)."""
    return (
        atom_type & 0x1F,
        (atom_type >> 5) & 0x03,
        (atom_type >> 7) & 0x01,
    )


def bin_partial_charge(charge: float) -> int:
    """Bin a partial charge into 4 discrete levels.

    Returns:
        0: strong negative (q < -0.25)
        1: weak negative   (-0.25 <= q < 0.0)
        2: weak positive   (0.0 <= q < 0.25)
        3: strong positive (q >= 0.25)
    """
    if charge < _CHARGE_THRESHOLDS[0]:
        return 0
    if charge < _CHARGE_THRESHOLDS[1]:
        return 1
    if charge < _CHARGE_THRESHOLDS[2]:
        return 2
    return 3


class AtomTyper:
    """Assigns 8-bit atom types to atoms in RDKit molecules.

    The typing scheme encodes:
    - Base type (5 bits): element + hybridization (32 types)
    - Charge bin (2 bits): discretized partial charge (4 bins)
    - H-bond flag (1 bit): donor or acceptor capability

    Total: 32 × 4 × 2 = 256 unique atom types.
    """

    def __init__(self, charge_method: str = "gasteiger"):
        """Initialize the atom typer.

        Args:
            charge_method: Method for partial charges.
                'gasteiger': Gasteiger charges via RDKit (fast, default)
        """
        self.charge_method = charge_method

    def assign_types(self, mol: Chem.Mol) -> np.ndarray:
        """Assign 8-bit atom types to all atoms in a molecule.

        Args:
            mol: RDKit Mol object (should have 3D coordinates for best results)

        Returns:
            numpy array of uint8 atom type indices, shape (n_atoms,)
        """
        from rdkit import Chem
        mol = Chem.RWMol(mol)

        # Compute partial charges
        charges = self._compute_charges(mol)

        # Identify H-bond donors and acceptors
        hbond_atoms = self._get_hbond_atoms(mol)

        # Assign types
        n_atoms = mol.GetNumAtoms()
        types = np.zeros(n_atoms, dtype=np.uint8)

        for idx in range(n_atoms):
            atom = mol.GetAtomWithIdx(idx)
            base = self._get_base_type(atom, mol)
            charge_bin = bin_partial_charge(charges[idx])
            hbond = 1 if idx in hbond_atoms else 0
            types[idx] = encode_atom_type(base, charge_bin, hbond)

        return types

    def assign_types_from_file(self, path: str) -> np.ndarray:
        """Assign types from a mol2 or SDF file.

        Args:
            path: Path to mol2 (.mol2) or SDF (.sdf) file.

        Returns:
            numpy array of uint8 atom type indices.
        """
        from rdkit import Chem

        path_lower = path.lower()
        if path_lower.endswith(".mol2"):
            mol = Chem.MolFromMol2File(path, removeHs=False)
        elif path_lower.endswith(".sdf"):
            supplier = Chem.SDMolSupplier(path, removeHs=False)
            mol = next(iter(supplier), None)
        else:
            raise ValueError(f"Unsupported file format: {path}")

        if mol is None:
            raise ValueError(f"Failed to parse molecule from {path}")

        return self.assign_types(mol)

    @staticmethod
    def _get_base_type_map():
        """Build the hybridization-based type map (requires rdkit)."""
        from rdkit import Chem
        _SP = Chem.HybridizationType.SP
        _SP2 = Chem.HybridizationType.SP2
        _SP3 = Chem.HybridizationType.SP3
        return {
            (6, _SP3): 0, (6, _SP2): 1, (6, _SP): 2,
            (7, _SP3): 4, (7, _SP2): 5, (7, _SP): 6,
            (8, _SP3): 9, (8, _SP2): 10,
            (16, _SP3): 12, (16, _SP2): 13,
            (15, _SP3): 14,
        }

    # Element-only types (no hybridization distinction)
    _ELEMENT_TYPE_MAP: dict[int, int] = {
        9: 15, 17: 16, 35: 17, 53: 18, 1: 19,
        26: 21, 30: 22, 12: 23, 20: 24, 25: 25,
        29: 26, 27: 27, 34: 28, 14: 29,
    }

    def _get_base_type(self, atom, mol) -> int:
        """Determine the 5-bit base type for an atom."""
        atomic_num = atom.GetAtomicNum()
        hybridization = atom.GetHybridization()

        # Check aromatic atoms first
        if atom.GetIsAromatic():
            if atomic_num == 6:
                return 3   # C_ar
            if atomic_num == 7:
                return 7   # N_ar
            if atomic_num == 8:
                return 11  # O_ar

        # Check amide nitrogen: N bonded to C=O
        if atomic_num == 7:
            for neighbor in atom.GetNeighbors():
                if neighbor.GetAtomicNum() == 6:
                    for nn in neighbor.GetNeighbors():
                        bond = mol.GetBondBetweenAtoms(
                            neighbor.GetIdx(), nn.GetIdx()
                        )
                        if (
                            nn.GetAtomicNum() == 8
                            and bond is not None
                            and bond.GetBondTypeAsDouble() == 2.0
                        ):
                            return 8  # N_am

        # Hybridization-based lookup
        base_type_map = self._get_base_type_map()
        key = (atomic_num, hybridization)
        if key in base_type_map:
            return base_type_map[key]

        # Polar hydrogen: H bonded to N, O, or S
        if atomic_num == 1:
            for neighbor in atom.GetNeighbors():
                if neighbor.GetAtomicNum() in (7, 8, 16):
                    return 20  # H_polar
            return 19  # H (non-polar)

        # Element-only lookup
        if atomic_num in self._ELEMENT_TYPE_MAP:
            return self._ELEMENT_TYPE_MAP[atomic_num]

        # Unknown — use Reserved_31
        return 31

    def _compute_charges(self, mol) -> List[float]:
        """Compute partial charges for all atoms."""
        from rdkit.Chem import AllChem
        AllChem.ComputeGasteigerCharges(mol)
        charges = []
        for atom in mol.GetAtoms():
            q = atom.GetDoubleProp("_GasteigerCharge")
            if np.isnan(q):
                q = 0.0
            charges.append(q)
        return charges

    def _get_hbond_atoms(self, mol) -> set[int]:
        """Identify atoms that are H-bond donors or acceptors."""
        from rdkit import Chem
        donor_smarts = Chem.MolFromSmarts("[#7H,#8H,#16H]")
        acceptor_smarts = Chem.MolFromSmarts(
            "[#7,#8,#16;!$([#7H2,#8H2]);!$([#7]~[#7])]"
        )
        hbond_atoms: set[int] = set()
        if donor_smarts is not None:
            for match in mol.GetSubstructMatches(donor_smarts):
                hbond_atoms.update(match)
        if acceptor_smarts is not None:
            for match in mol.GetSubstructMatches(acceptor_smarts):
                hbond_atoms.update(match)
        return hbond_atoms
