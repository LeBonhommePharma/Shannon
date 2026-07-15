# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# shannon_contact — 256×256 Soft Contact Interaction Matrix
#
# Upgrade of FlexAID's 40×40 CF matrix at force-field resolution.
# 8-bit atom type encoding: element+hybridization (5 bits) +
# partial charge bin (2 bits) + H-bond flag (1 bit) = 256 types.

"""256×256 soft contact interaction matrix for molecular docking scoring."""

__version__ = "0.1.0"

from shannon_contact.matrix import SoftContactMatrix, ATOM_TYPE_SCHEMA_ID
from shannon_contact.atom_typer import encode_atom_type, decode_atom_type, bin_partial_charge

# AtomTyper requires rdkit — lazy import to allow matrix-only usage
def __getattr__(name):
    if name == "AtomTyper":
        from shannon_contact.atom_typer import AtomTyper
        return AtomTyper
    raise AttributeError(f"module 'shannon_contact' has no attribute {name}")

__all__ = [
    "SoftContactMatrix",
    "ATOM_TYPE_SCHEMA_ID",
    "AtomTyper",
    "encode_atom_type",
    "decode_atom_type",
    "bin_partial_charge",
]
