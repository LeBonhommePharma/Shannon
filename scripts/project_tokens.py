#!/usr/bin/env python3
# =============================================================================
# project_tokens.py — Map Token Embeddings to 256-Bin Type Space
#
# One-time contrastive fine-tune: projects LLM token embeddings into the
# same 256-bin physicochemical space used by the ShannonEnergyMatrix.
#
# The projection is a learned linear map W (d_model -> 256) trained via
# contrastive loss on paired docking + LLM traces:
#   L = -log(exp(sim(z_i, z_j^+)) / sum(exp(sim(z_i, z_k))))
#
# After training, W is frozen and shipped with the library.
#
# Usage:
#   python scripts/project_tokens.py --embeddings embeddings.npy --output projection.bin
#
# Copyright 2024-2026 Louis-Philippe Morency
# Licensed under the Apache License, Version 2.0
# =============================================================================

from __future__ import annotations

import argparse
import struct
from pathlib import Path

import numpy as np


def create_random_projection(d_model: int, n_bins: int = 256, seed: int = 42) -> np.ndarray:
    """Create an initial random projection matrix.

    For production: replace with contrastive-trained projection from paired
    docking + LLM trace data. This random orthogonal projection serves as a
    reasonable baseline for testing.
    """
    rng = np.random.default_rng(seed)
    # Random orthogonal initialization (Gram-Schmidt on random matrix)
    A = rng.standard_normal((d_model, n_bins)).astype(np.float32)
    Q, _ = np.linalg.qr(A)
    return Q[:, :n_bins].astype(np.float32)


def project_embeddings(
    embeddings: np.ndarray,
    projection: np.ndarray,
) -> np.ndarray:
    """Project token embeddings to 256-bin type indices.

    Parameters
    ----------
    embeddings : (n_tokens, d_model) float32
    projection : (d_model, 256) float32

    Returns
    -------
    type_indices : (n_tokens,) uint8
        The 256-bin type index for each token.
    """
    # Project to 256-d space
    z = embeddings @ projection  # (n_tokens, 256)

    # Argmax to get the dominant bin
    type_indices = np.argmax(z, axis=1).astype(np.uint8)

    return type_indices


def decode_type_index(t: int) -> dict:
    """Decode an 8-bit type index into its semantic components."""
    return {
        "type_index": t,
        "base_type": t & 0x1F,
        "charge_bin": (t >> 5) & 0x03,
        "charge_label": ["strong-", "weak-", "weak+", "strong+"][(t >> 5) & 0x03],
        "hbond": bool((t >> 7) & 0x01),
    }


def save_projection(projection: np.ndarray, path: Path) -> None:
    """Save projection matrix as binary blob."""
    d_model, n_bins = projection.shape
    with open(path, "wb") as f:
        f.write(b"TP01")  # magic: Token Projection v01
        f.write(struct.pack("<II", d_model, n_bins))
        f.write(projection.astype(np.float32).tobytes())
    print(f"Saved projection ({d_model} x {n_bins}) to {path}")


def load_projection(path: Path) -> np.ndarray:
    """Load projection matrix from binary blob."""
    with open(path, "rb") as f:
        magic = f.read(4)
        assert magic == b"TP01", f"Invalid magic: {magic}"
        d_model, n_bins = struct.unpack("<II", f.read(8))
        data = np.frombuffer(f.read(), dtype=np.float32)
        return data.reshape(d_model, n_bins)


# =============================================================================
# Contrastive training stub
# =============================================================================

def contrastive_train(
    docking_embeddings: np.ndarray,
    llm_embeddings: np.ndarray,
    d_model: int,
    n_bins: int = 256,
    n_epochs: int = 100,
    lr: float = 1e-3,
    temperature: float = 0.07,
) -> np.ndarray:
    """Train projection via contrastive loss on paired data.

    This is a stub for the full training pipeline. For production:
    1. Collect paired (docking_trace, llm_trace) data
    2. Extract embeddings from both domains
    3. Train W to maximize cross-domain alignment
    4. Validate on held-out CASF-2016 pairs
    5. Freeze W and ship as projection.bin

    Parameters
    ----------
    docking_embeddings : (n_pairs, d_dock) paired docking trace embeddings
    llm_embeddings : (n_pairs, d_model) paired LLM trace embeddings
    d_model : dimension of LLM embeddings
    n_bins : target dimension (256)
    n_epochs : training epochs
    lr : learning rate
    temperature : InfoNCE temperature

    Returns
    -------
    projection : (d_model, n_bins) trained projection matrix
    """
    # Stub: return random orthogonal projection
    # Full implementation requires torch or jax for gradient-based optimization
    print("WARNING: Using random projection (contrastive training not implemented)")
    print("For production, implement InfoNCE contrastive loss on paired data.")
    return create_random_projection(d_model, n_bins)


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Project token embeddings to 256-bin type space"
    )
    parser.add_argument(
        "--embeddings", type=Path,
        help="Path to token embeddings (.npy, shape: n_tokens x d_model)",
    )
    parser.add_argument(
        "--d-model", type=int, default=4096,
        help="Model embedding dimension (default: 4096 for LLaMA-scale)",
    )
    parser.add_argument(
        "--output", "-o", type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "token_projection.bin",
        help="Output path for projection matrix",
    )
    parser.add_argument(
        "--demo", action="store_true",
        help="Run a demo with random embeddings",
    )
    args = parser.parse_args()

    if args.demo:
        print(f"Creating random projection for d_model={args.d_model}...")
        W = create_random_projection(args.d_model)
        save_projection(W, args.output)

        # Demo: project random embeddings
        rng = np.random.default_rng(123)
        fake_embeddings = rng.standard_normal((10, args.d_model)).astype(np.float32)
        types = project_embeddings(fake_embeddings, W)

        print("\nDemo type assignments:")
        for i, t in enumerate(types):
            info = decode_type_index(int(t))
            print(f"  Token {i}: type={info['type_index']:3d}  "
                  f"base={info['base_type']:2d}  "
                  f"charge={info['charge_label']:8s}  "
                  f"hbond={info['hbond']}")

    elif args.embeddings:
        embeddings = np.load(args.embeddings)
        print(f"Loaded embeddings: {embeddings.shape}")
        d_model = embeddings.shape[1]
        W = create_random_projection(d_model)
        save_projection(W, args.output)
        types = project_embeddings(embeddings, W)
        print(f"Projected {len(types)} tokens to 256-bin space")
        np.save(args.output.with_suffix(".types.npy"), types)
    else:
        print("Use --demo for a demo or --embeddings for real data")
        parser.print_help()


if __name__ == "__main__":
    main()
