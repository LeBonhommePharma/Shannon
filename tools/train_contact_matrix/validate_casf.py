#!/usr/bin/env python3
# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
#
# Step 4: Validate the trained 256×256 matrix on CASF-2016 benchmarks.
# Tests scoring power (Pearson r), ranking power, and docking power.

"""Validate the soft contact matrix on CASF-2016 benchmarks."""

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path

import numpy as np
from scipy.stats import pearsonr, spearmanr

from shannon_contact.matrix import SoftContactMatrix
from shannon_contact.pose_encoder import PoseEncoder

logger = logging.getLogger(__name__)


def load_casf_targets(casf_dir: Path) -> dict[str, float]:
    """Load CASF-2016 target binding affinities.

    Reads CoreSet.dat or similar index file.
    """
    targets = {}
    index_file = casf_dir / "CoreSet.dat"
    if not index_file.exists():
        # Try alternative names
        for name in ["index.txt", "core_set.txt", "CoreSet.txt"]:
            alt = casf_dir / name
            if alt.exists():
                index_file = alt
                break

    if not index_file.exists():
        raise FileNotFoundError(
            f"No CASF index file found in {casf_dir}. "
            f"Expected CoreSet.dat or similar."
        )

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
                    targets[pdb_id] = affinity
                except ValueError:
                    continue

    return targets


def score_complex(
    matrix: SoftContactMatrix,
    encoder: PoseEncoder,
    typed_record: dict,
) -> float:
    """Score a single complex using the contact matrix."""
    protein_types = np.array(typed_record["protein_types"], dtype=np.uint8)
    ligand_types = np.array(typed_record["ligand_types"], dtype=np.uint8)
    protein_coords = np.array(typed_record["protein_coords"], dtype=np.float64)
    ligand_coords = np.array(typed_record["ligand_coords"], dtype=np.float64)

    return encoder.score_pose(
        protein_types, ligand_types, protein_coords, ligand_coords
    )


def scoring_power(
    predicted: np.ndarray,
    experimental: np.ndarray,
) -> dict:
    """Compute scoring power metrics.

    Returns Pearson r, Spearman rho, RMSE, and standard deviation.
    """
    r, p_r = pearsonr(experimental, predicted)
    rho, p_rho = spearmanr(experimental, predicted)
    rmse = np.sqrt(np.mean((predicted - experimental) ** 2))
    sd = np.std(predicted - experimental)

    return {
        "pearson_r": float(r),
        "pearson_p": float(p_r),
        "spearman_rho": float(rho),
        "spearman_p": float(p_rho),
        "rmse": float(rmse),
        "sd": float(sd),
        "n": len(predicted),
    }


def ranking_power(
    pdb_ids: list[str],
    predicted: np.ndarray,
    experimental: np.ndarray,
    targets_per_cluster: int = 3,
) -> dict:
    """Compute pairwise concordance over all complex pairs.

    NOTE: This is a simplified all-pairs concordance metric, NOT the
    official CASF-2016 target-clustered ranking power.  The official
    metric groups complexes by protein target and evaluates within-cluster
    ranking.  This implementation treats all complexes as one flat set.
    """
    n_correct = 0
    n_total = 0

    for i in range(len(predicted)):
        for j in range(i + 1, len(predicted)):
            pred_order = predicted[i] > predicted[j]
            exp_order = experimental[i] > experimental[j]
            if pred_order == exp_order:
                n_correct += 1
            n_total += 1

    concordance = n_correct / n_total if n_total > 0 else 0.0

    return {
        "concordance": concordance,
        "n_pairs": n_total,
        "n_correct": n_correct,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Validate contact matrix on CASF-2016."
    )
    parser.add_argument(
        "matrix_path",
        type=Path,
        help="Path to trained 256×256 matrix binary.",
    )
    parser.add_argument(
        "typed_atoms",
        type=Path,
        help="JSONL file of typed CASF complexes.",
    )
    parser.add_argument(
        "-c", "--casf-dir",
        type=Path,
        required=True,
        help="CASF-2016 directory with CoreSet.dat.",
    )
    parser.add_argument(
        "-o", "--output",
        type=Path,
        default=Path("casf_validation.json"),
        help="Output JSON report.",
    )
    parser.add_argument(
        "--cutoff",
        type=float,
        default=12.0,
        help="Contact cutoff (default: 12.0).",
    )
    parser.add_argument(
        "--sigma",
        type=float,
        default=3.0,
        help="Gaussian sigma (default: 3.0).",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    # Load matrix
    matrix = SoftContactMatrix(path=str(args.matrix_path))
    encoder = PoseEncoder(matrix, cutoff=args.cutoff, sigma=args.sigma)
    logger.info(f"Loaded matrix from {args.matrix_path}")

    # Load CASF targets
    targets = load_casf_targets(args.casf_dir)
    logger.info(f"Loaded {len(targets)} CASF targets")

    # Score all complexes
    pdb_ids = []
    predicted = []
    experimental = []

    with open(args.typed_atoms) as f:
        for line in f:
            record = json.loads(line)
            pdb_id = record["pdb_id"].lower()

            if pdb_id not in targets:
                continue

            score = score_complex(matrix, encoder, record)
            pdb_ids.append(pdb_id)
            predicted.append(score)
            experimental.append(targets[pdb_id])

    predicted = np.array(predicted)
    experimental = np.array(experimental)
    logger.info(f"Scored {len(pdb_ids)} CASF complexes")

    # Compute metrics
    sp = scoring_power(predicted, experimental)
    rp = ranking_power(pdb_ids, predicted, experimental)

    results = {
        "scoring_power": sp,
        "ranking_power": rp,
        "matrix_path": str(args.matrix_path),
        "n_complexes": len(pdb_ids),
    }

    # Save report
    with open(args.output, "w") as f:
        json.dump(results, f, indent=2)

    logger.info("=== CASF-2016 Validation Results ===")
    logger.info(f"  Scoring power:  Pearson r = {sp['pearson_r']:.3f}")
    logger.info(f"                  Spearman ρ = {sp['spearman_rho']:.3f}")
    logger.info(f"                  RMSE = {sp['rmse']:.3f}")
    logger.info(f"  Ranking power:  Concordance = {rp['concordance']:.3f}")
    logger.info(f"  Report saved to {args.output}")


if __name__ == "__main__":
    main()
