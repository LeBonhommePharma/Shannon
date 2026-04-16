#!/usr/bin/env python3
# =============================================================================
# project_tokens.py — Map Token Embeddings to 256-Bin Type Space
#
# One-time contrastive fine-tune: projects LLM token embeddings into the
# same 256-bin physicochemical space used by the ShannonEnergyMatrix.
#
# The projection is a learned linear map W (d_model -> 256) trained via
# InfoNCE contrastive loss on paired docking + LLM traces:
#   L = -log(exp(sim(z_i, z_j^+) / tau) / sum(exp(sim(z_i, z_k) / tau)))
#
# Training uses pure numpy gradient descent (no torch/jax dependency).
# After training, W is frozen and shipped with the library.
#
# Usage:
#   python scripts/project_tokens.py --train --docking dock.npy --llm llm.npy
#   python scripts/project_tokens.py --embeddings embeddings.npy --output projection.bin
#   python scripts/project_tokens.py --demo
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

def decode_type_index(t: int) -> dict:
    """Decode an 8-bit type index into its semantic components."""
    return {
        "type_index": t,
        "base_type": t & 0x1F,
        "charge_bin": (t >> 5) & 0x03,
        "charge_label": ["strong-", "weak-", "weak+", "strong+"][(t >> 5) & 0x03],
        "hbond": bool((t >> 7) & 0x01),
    }


# =============================================================================
# Projection I/O
# =============================================================================

def save_projection(projection: np.ndarray, path: Path) -> None:
    """Save projection matrix as binary blob (TP01 format)."""
    d_model, n_bins = projection.shape
    with open(path, "wb") as f:
        f.write(b"TP01")  # magic: Token Projection v01
        f.write(struct.pack("<II", d_model, n_bins))
        f.write(projection.astype(np.float32).tobytes())
    print(f"Saved projection ({d_model} x {n_bins}) to {path}")


def load_projection(path: Path) -> np.ndarray:
    """Load projection matrix from binary blob (TP01 format)."""
    with open(path, "rb") as f:
        magic = f.read(4)
        assert magic == b"TP01", f"Invalid magic: {magic}"
        d_model, n_bins = struct.unpack("<II", f.read(8))
        data = np.frombuffer(f.read(), dtype=np.float32)
        return data.reshape(d_model, n_bins)


# =============================================================================
# Projection application
# =============================================================================

def create_random_projection(d_model: int, n_bins: int = 256, seed: int = 42) -> np.ndarray:
    """Create an initial random orthogonal projection matrix."""
    rng = np.random.default_rng(seed)
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
    """
    z = embeddings @ projection  # (n_tokens, 256)
    return np.argmax(z, axis=1).astype(np.uint8)


# =============================================================================
# InfoNCE contrastive loss — pure numpy implementation
# =============================================================================

def _l2_normalize(x: np.ndarray, axis: int = -1, eps: float = 1e-8) -> np.ndarray:
    """L2-normalize along axis."""
    norm = np.sqrt(np.sum(x * x, axis=axis, keepdims=True) + eps)
    return x / norm


def info_nce_loss(
    z_anchor: np.ndarray,
    z_positive: np.ndarray,
    temperature: float = 0.07,
) -> tuple[float, np.ndarray, np.ndarray]:
    """Compute InfoNCE contrastive loss and gradients.

    L = -mean_i[ log( exp(sim(z_i, z_i^+) / tau) / sum_j(exp(sim(z_i, z_j^+) / tau)) ) ]

    where sim(a, b) = a^T b / (||a|| ||b||) (cosine similarity).

    Parameters
    ----------
    z_anchor : (batch, d) L2-normalized anchor embeddings
    z_positive : (batch, d) L2-normalized positive embeddings
    temperature : scalar temperature for softmax sharpness

    Returns
    -------
    loss : scalar InfoNCE loss
    grad_anchor : (batch, d) gradient w.r.t. z_anchor
    grad_positive : (batch, d) gradient w.r.t. z_positive
    """
    batch = z_anchor.shape[0]

    # Cosine similarity matrix: (batch, batch)
    # sim[i,j] = z_anchor[i] . z_positive[j]
    sim = z_anchor @ z_positive.T / temperature  # (batch, batch)

    # Numerical stability: subtract row max
    sim_max = np.max(sim, axis=1, keepdims=True)
    sim_stable = sim - sim_max

    exp_sim = np.exp(sim_stable)  # (batch, batch)
    row_sums = np.sum(exp_sim, axis=1, keepdims=True)  # (batch, 1)

    # Softmax probabilities
    softmax = exp_sim / row_sums  # (batch, batch)

    # Loss: -mean of log(softmax[i,i])
    log_probs = np.log(softmax[np.arange(batch), np.arange(batch)] + 1e-15)
    loss = -np.mean(log_probs)

    # Gradient of loss w.r.t. sim matrix
    # d(loss)/d(sim[i,j]) = (1/batch) * (softmax[i,j] - delta_{i,j})
    grad_sim = softmax.copy()
    grad_sim[np.arange(batch), np.arange(batch)] -= 1.0
    grad_sim /= batch

    # Chain rule to z_anchor and z_positive
    # sim = z_anchor @ z_positive.T / tau
    # d(loss)/d(z_anchor) = grad_sim @ z_positive / tau
    # d(loss)/d(z_positive) = grad_sim.T @ z_anchor / tau
    grad_anchor = grad_sim @ z_positive / temperature
    grad_positive = grad_sim.T @ z_anchor / temperature

    return loss, grad_anchor, grad_positive


def _compute_alignment_accuracy(z_a: np.ndarray, z_p: np.ndarray) -> float:
    """Fraction of anchors whose nearest positive is the correct pair."""
    sim = z_a @ z_p.T
    predictions = np.argmax(sim, axis=1)
    return float(np.mean(predictions == np.arange(len(z_a))))


# =============================================================================
# Contrastive training — full implementation
# =============================================================================

class ContrastiveProjectionTrainer:
    """Train a linear projection W: R^d_model -> R^n_bins via InfoNCE.

    The projection maps LLM token embeddings into the same 256-bin
    physicochemical type space as the ShannonEnergyMatrix. Training
    maximizes alignment between paired docking and LLM trace embeddings
    in the projected space.

    Uses Adam optimizer with cosine learning rate decay, implemented in
    pure numpy (no torch/jax dependency).
    """

    def __init__(
        self,
        d_model: int,
        d_dock: int,
        n_bins: int = 256,
        temperature: float = 0.07,
        lr: float = 1e-3,
        weight_decay: float = 1e-4,
        seed: int = 42,
    ):
        self.d_model = d_model
        self.d_dock = d_dock
        self.n_bins = n_bins
        self.temperature = temperature
        self.lr = lr
        self.weight_decay = weight_decay
        self.rng = np.random.default_rng(seed)

        # Projection matrices: LLM -> n_bins and docking -> n_bins
        # Xavier initialization: scale = sqrt(2 / (fan_in + fan_out))
        scale_llm = np.sqrt(2.0 / (d_model + n_bins))
        scale_dock = np.sqrt(2.0 / (d_dock + n_bins))
        self.W_llm = (self.rng.standard_normal((d_model, n_bins)) * scale_llm).astype(np.float64)
        self.W_dock = (self.rng.standard_normal((d_dock, n_bins)) * scale_dock).astype(np.float64)

        # Adam state
        self._m_llm = np.zeros_like(self.W_llm)
        self._v_llm = np.zeros_like(self.W_llm)
        self._m_dock = np.zeros_like(self.W_dock)
        self._v_dock = np.zeros_like(self.W_dock)
        self._step = 0

    def _adam_update(
        self, param: np.ndarray, grad: np.ndarray,
        m: np.ndarray, v: np.ndarray,
        lr: float, beta1: float = 0.9, beta2: float = 0.999, eps: float = 1e-8,
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """Adam optimizer step (in-place on m, v)."""
        m[:] = beta1 * m + (1 - beta1) * grad
        v[:] = beta2 * v + (1 - beta2) * (grad * grad)

        # Bias correction
        m_hat = m / (1 - beta1 ** self._step)
        v_hat = v / (1 - beta2 ** self._step)

        # Weight decay (decoupled, AdamW-style)
        param -= lr * (m_hat / (np.sqrt(v_hat) + eps) + self.weight_decay * param)

        return param, m, v

    def train_step(
        self,
        llm_batch: np.ndarray,
        dock_batch: np.ndarray,
        lr: float,
    ) -> tuple[float, float]:
        """Single training step on a minibatch.

        Parameters
        ----------
        llm_batch : (batch, d_model) LLM embeddings
        dock_batch : (batch, d_dock) docking embeddings (paired)
        lr : current learning rate

        Returns
        -------
        loss : InfoNCE loss value
        accuracy : alignment accuracy (fraction of correct nearest-neighbor)
        """
        self._step += 1

        # Forward: project both domains to n_bins space
        z_llm = llm_batch @ self.W_llm    # (batch, n_bins)
        z_dock = dock_batch @ self.W_dock  # (batch, n_bins)

        # L2 normalize
        z_llm_norm = _l2_normalize(z_llm)
        z_dock_norm = _l2_normalize(z_dock)

        # InfoNCE loss + gradients
        loss, grad_z_llm, grad_z_dock = info_nce_loss(
            z_llm_norm, z_dock_norm, self.temperature
        )

        # Backprop through L2 normalization
        # d(normalize(x))/dx = (I - x_hat x_hat^T) / ||x||
        def grad_through_normalize(z_raw, z_normed, grad_normed):
            norm = np.sqrt(np.sum(z_raw * z_raw, axis=-1, keepdims=True) + 1e-8)
            # (I - z_hat z_hat^T) @ grad / ||z||
            dot = np.sum(z_normed * grad_normed, axis=-1, keepdims=True)
            return (grad_normed - z_normed * dot) / norm

        grad_z_llm_raw = grad_through_normalize(z_llm, z_llm_norm, grad_z_llm)
        grad_z_dock_raw = grad_through_normalize(z_dock, z_dock_norm, grad_z_dock)

        # Gradient w.r.t. projection matrices
        # z = x @ W => dL/dW = x^T @ dL/dz
        grad_W_llm = llm_batch.T @ grad_z_llm_raw
        grad_W_dock = dock_batch.T @ grad_z_dock_raw

        # Adam update
        self.W_llm, self._m_llm, self._v_llm = self._adam_update(
            self.W_llm, grad_W_llm, self._m_llm, self._v_llm, lr)
        self.W_dock, self._m_dock, self._v_dock = self._adam_update(
            self.W_dock, grad_W_dock, self._m_dock, self._v_dock, lr)

        accuracy = _compute_alignment_accuracy(z_llm_norm, z_dock_norm)
        return loss, accuracy

    def train(
        self,
        llm_embeddings: np.ndarray,
        dock_embeddings: np.ndarray,
        n_epochs: int = 100,
        batch_size: int = 256,
        val_split: float = 0.1,
        verbose: bool = True,
    ) -> dict:
        """Full training loop with cosine LR decay and validation.

        Parameters
        ----------
        llm_embeddings : (n_pairs, d_model) LLM trace embeddings
        dock_embeddings : (n_pairs, d_dock) paired docking trace embeddings
        n_epochs : number of training epochs
        batch_size : minibatch size
        val_split : fraction held out for validation
        verbose : print progress

        Returns
        -------
        history : dict with 'train_loss', 'train_acc', 'val_loss', 'val_acc' lists
        """
        n = len(llm_embeddings)
        assert n == len(dock_embeddings), "Paired data must have equal length"

        # Train/val split
        n_val = max(1, int(n * val_split))
        n_train = n - n_val
        perm = self.rng.permutation(n)
        train_idx = perm[:n_train]
        val_idx = perm[n_train:]

        llm_train = llm_embeddings[train_idx].astype(np.float64)
        dock_train = dock_embeddings[train_idx].astype(np.float64)
        llm_val = llm_embeddings[val_idx].astype(np.float64)
        dock_val = dock_embeddings[val_idx].astype(np.float64)

        history = {
            "train_loss": [], "train_acc": [],
            "val_loss": [], "val_acc": [],
        }

        total_steps = n_epochs * max(1, n_train // batch_size)

        for epoch in range(n_epochs):
            # Shuffle training data each epoch
            epoch_perm = self.rng.permutation(n_train)
            llm_shuffled = llm_train[epoch_perm]
            dock_shuffled = dock_train[epoch_perm]

            epoch_losses = []
            epoch_accs = []

            for start in range(0, n_train, batch_size):
                end = min(start + batch_size, n_train)
                if end - start < 4:
                    continue  # Need at least 4 samples for meaningful contrastive

                # Cosine LR decay
                progress = self._step / max(total_steps, 1)
                lr = self.lr * 0.5 * (1 + np.cos(np.pi * progress))
                lr = max(lr, self.lr * 0.01)  # floor at 1% of initial

                loss, acc = self.train_step(
                    llm_shuffled[start:end],
                    dock_shuffled[start:end],
                    lr,
                )
                epoch_losses.append(loss)
                epoch_accs.append(acc)

            # Epoch metrics
            train_loss = float(np.mean(epoch_losses)) if epoch_losses else 0.0
            train_acc = float(np.mean(epoch_accs)) if epoch_accs else 0.0
            history["train_loss"].append(train_loss)
            history["train_acc"].append(train_acc)

            # Validation
            val_loss, val_acc = self._evaluate(llm_val, dock_val)
            history["val_loss"].append(val_loss)
            history["val_acc"].append(val_acc)

            if verbose and (epoch % 10 == 0 or epoch == n_epochs - 1):
                print(f"  Epoch {epoch:4d}/{n_epochs}  "
                      f"train_loss={train_loss:.4f}  train_acc={train_acc:.3f}  "
                      f"val_loss={val_loss:.4f}  val_acc={val_acc:.3f}  "
                      f"lr={lr:.2e}")

        return history

    def _evaluate(
        self,
        llm_data: np.ndarray,
        dock_data: np.ndarray,
    ) -> tuple[float, float]:
        """Evaluate loss and accuracy on held-out data (no gradient)."""
        z_llm = _l2_normalize(llm_data @ self.W_llm)
        z_dock = _l2_normalize(dock_data @ self.W_dock)

        loss, _, _ = info_nce_loss(z_llm, z_dock, self.temperature)
        accuracy = _compute_alignment_accuracy(z_llm, z_dock)
        return float(loss), float(accuracy)

    def get_llm_projection(self) -> np.ndarray:
        """Get the trained LLM projection matrix (d_model, n_bins)."""
        return self.W_llm.astype(np.float32)

    def get_dock_projection(self) -> np.ndarray:
        """Get the trained docking projection matrix (d_dock, n_bins)."""
        return self.W_dock.astype(np.float32)


# =============================================================================
# Synthetic paired data generation (for testing and development)
# =============================================================================

def generate_synthetic_pairs(
    n_pairs: int = 5000,
    d_model: int = 512,
    d_dock: int = 128,
    n_concepts: int = 32,
    seed: int = 42,
) -> tuple[np.ndarray, np.ndarray]:
    """Generate synthetic paired (docking, LLM) embeddings for training.

    Creates paired data where both domains share latent structure:
    each pair is generated from the same latent concept (one of n_concepts),
    projected through domain-specific random matrices plus noise.

    Parameters
    ----------
    n_pairs : number of paired samples
    d_model : LLM embedding dimension
    d_dock : docking embedding dimension
    n_concepts : number of latent concepts (shared structure)
    seed : RNG seed

    Returns
    -------
    dock_embeddings : (n_pairs, d_dock)
    llm_embeddings : (n_pairs, d_model)
    """
    rng = np.random.default_rng(seed)

    # Latent concept prototypes
    concepts = rng.standard_normal((n_concepts, 64)).astype(np.float32)

    # Domain-specific projection matrices (latent -> observed)
    P_dock = rng.standard_normal((64, d_dock)).astype(np.float32) * 0.1
    P_llm = rng.standard_normal((64, d_model)).astype(np.float32) * 0.1

    # Generate pairs
    dock_embeddings = np.zeros((n_pairs, d_dock), dtype=np.float32)
    llm_embeddings = np.zeros((n_pairs, d_model), dtype=np.float32)

    for i in range(n_pairs):
        concept_idx = rng.integers(n_concepts)
        latent = concepts[concept_idx]

        # Project to each domain + add noise
        dock_embeddings[i] = latent @ P_dock + rng.standard_normal(d_dock).astype(np.float32) * 0.05
        llm_embeddings[i] = latent @ P_llm + rng.standard_normal(d_model).astype(np.float32) * 0.05

    return dock_embeddings, llm_embeddings


# =============================================================================
# Main
# =============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Project token embeddings to 256-bin type space via InfoNCE contrastive training"
    )
    subparsers = parser.add_subparsers(dest="command")

    # Train subcommand
    train_parser = subparsers.add_parser("train", help="Train projection from paired data")
    train_parser.add_argument("--docking", type=Path, help="Docking embeddings (.npy)")
    train_parser.add_argument("--llm", type=Path, help="LLM embeddings (.npy)")
    train_parser.add_argument("--synthetic", action="store_true",
                              help="Use synthetic paired data for training")
    train_parser.add_argument("--n-pairs", type=int, default=5000,
                              help="Number of synthetic pairs (default: 5000)")
    train_parser.add_argument("--d-model", type=int, default=512,
                              help="LLM embedding dimension (default: 512)")
    train_parser.add_argument("--d-dock", type=int, default=128,
                              help="Docking embedding dimension (default: 128)")
    train_parser.add_argument("--epochs", type=int, default=100,
                              help="Training epochs (default: 100)")
    train_parser.add_argument("--batch-size", type=int, default=256,
                              help="Batch size (default: 256)")
    train_parser.add_argument("--lr", type=float, default=1e-3,
                              help="Learning rate (default: 1e-3)")
    train_parser.add_argument("--temperature", type=float, default=0.07,
                              help="InfoNCE temperature (default: 0.07)")
    train_parser.add_argument("--output", "-o", type=Path,
                              default=Path(__file__).resolve().parent.parent / "data" / "token_projection.bin")

    # Project subcommand
    proj_parser = subparsers.add_parser("project", help="Apply trained projection to embeddings")
    proj_parser.add_argument("--embeddings", type=Path, required=True,
                             help="Token embeddings (.npy)")
    proj_parser.add_argument("--projection", type=Path, required=True,
                             help="Trained projection matrix (.bin)")
    proj_parser.add_argument("--output", "-o", type=Path, default=None,
                             help="Output type indices (.npy)")

    # Demo subcommand
    demo_parser = subparsers.add_parser("demo", help="Run full training demo with synthetic data")
    demo_parser.add_argument("--d-model", type=int, default=256)
    demo_parser.add_argument("--d-dock", type=int, default=64)
    demo_parser.add_argument("--n-pairs", type=int, default=2000)
    demo_parser.add_argument("--epochs", type=int, default=50)
    demo_parser.add_argument("--output", "-o", type=Path,
                             default=Path(__file__).resolve().parent.parent / "data" / "token_projection.bin")

    args = parser.parse_args()

    if args.command == "train":
        if args.synthetic:
            print(f"Generating {args.n_pairs} synthetic paired embeddings...")
            dock_emb, llm_emb = generate_synthetic_pairs(
                n_pairs=args.n_pairs,
                d_model=args.d_model,
                d_dock=args.d_dock,
            )
        elif args.docking and args.llm:
            dock_emb = np.load(args.docking)
            llm_emb = np.load(args.llm)
            args.d_model = llm_emb.shape[1]
            args.d_dock = dock_emb.shape[1]
            print(f"Loaded docking: {dock_emb.shape}, LLM: {llm_emb.shape}")
        else:
            print("Provide --docking and --llm paths, or use --synthetic")
            sys.exit(1)

        print(f"\nTraining InfoNCE contrastive projection:")
        print(f"  d_model={args.d_model}, d_dock={args.d_dock}, n_bins=256")
        print(f"  epochs={args.epochs}, batch_size={args.batch_size}")
        print(f"  lr={args.lr}, temperature={args.temperature}")
        print()

        trainer = ContrastiveProjectionTrainer(
            d_model=args.d_model,
            d_dock=args.d_dock,
            temperature=args.temperature,
            lr=args.lr,
        )
        history = trainer.train(
            llm_emb, dock_emb,
            n_epochs=args.epochs,
            batch_size=args.batch_size,
        )

        W = trainer.get_llm_projection()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        save_projection(W, args.output)

        print(f"\nFinal train_acc={history['train_acc'][-1]:.3f}  "
              f"val_acc={history['val_acc'][-1]:.3f}")

    elif args.command == "project":
        embeddings = np.load(args.embeddings)
        W = load_projection(args.projection)
        print(f"Loaded embeddings: {embeddings.shape}, projection: {W.shape}")

        types = project_embeddings(embeddings, W)
        out_path = args.output or args.embeddings.with_suffix(".types.npy")
        np.save(out_path, types)
        print(f"Projected {len(types)} tokens to 256-bin space -> {out_path}")

        # Show distribution
        counts = np.bincount(types, minlength=256)
        active = np.count_nonzero(counts)
        print(f"Active bins: {active}/256, max count: {counts.max()}, "
              f"min nonzero: {counts[counts > 0].min()}")

    elif args.command == "demo":
        print("=== InfoNCE Contrastive Projection Training Demo ===\n")
        print(f"Generating {args.n_pairs} synthetic paired embeddings...")
        dock_emb, llm_emb = generate_synthetic_pairs(
            n_pairs=args.n_pairs,
            d_model=args.d_model,
            d_dock=args.d_dock,
        )

        trainer = ContrastiveProjectionTrainer(
            d_model=args.d_model,
            d_dock=args.d_dock,
            lr=3e-3,
            temperature=0.07,
        )

        print(f"\nTraining: d_model={args.d_model}, d_dock={args.d_dock}, "
              f"n_bins=256, epochs={args.epochs}\n")

        history = trainer.train(
            llm_emb, dock_emb,
            n_epochs=args.epochs,
            batch_size=128,
        )

        W = trainer.get_llm_projection()
        args.output.parent.mkdir(parents=True, exist_ok=True)
        save_projection(W, args.output)

        # Project some test embeddings
        test_emb = llm_emb[:10]
        types = project_embeddings(test_emb, W)

        print(f"\nFinal: train_loss={history['train_loss'][-1]:.4f}  "
              f"val_acc={history['val_acc'][-1]:.3f}")
        print(f"\nSample type assignments:")
        for i, t in enumerate(types):
            info = decode_type_index(int(t))
            print(f"  Token {i}: type={info['type_index']:3d}  "
                  f"base={info['base_type']:2d}  "
                  f"charge={info['charge_label']:8s}  "
                  f"hbond={info['hbond']}")

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
