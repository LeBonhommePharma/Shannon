// =============================================================================
// ShannonEnergyMatrix — 256x256 White-Box Physicochemical Referee
//
// Ported from FlexAIDdS ShannonEnergyMatrix singleton.
// The energy values encode pairwise physicochemical complementarity scores
// derived from statistical mechanics principles. Each E[i][j] represents
// the interaction energy between token type i and token type j, analogous
// to atom-type pairwise potentials in molecular docking.
//
// The matrix is symmetric and initialized from a closed-form potential
// combining van der Waals, electrostatic screening, and desolvation terms,
// all projected onto the 256-dimensional byte space.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include "energy_matrix.h"
#include <cmath>
#include <numbers>

namespace shannon {

const ShannonEnergyMatrix& ShannonEnergyMatrix::instance() {
    static ShannonEnergyMatrix inst;
    return inst;
}

ShannonEnergyMatrix::ShannonEnergyMatrix() {
    initialize();
}

void ShannonEnergyMatrix::initialize() {
    // Physicochemical potential: combines van der Waals repulsion/attraction,
    // Debye-Huckel electrostatic screening, and desolvation penalty.
    //
    // E(i,j) = epsilon_ij * [ (sigma/r)^12 - 2*(sigma/r)^6 ]
    //        + q_i * q_j * exp(-kappa*r) / (4*pi*eps0*r)
    //        + gamma * (SA_i + SA_j)
    //
    // Projected onto byte indices [0,255] where:
    //   r_ij = |i - j| / 255.0 * r_max + r_min
    //   Charge class from i%16, size class from i/16
    //
    // This gives a fully interpretable, auditable 256x256 parameter set.

    constexpr double r_min    = 1.0;    // Angstroms — minimum distance
    constexpr double r_max    = 12.0;   // Angstroms — cutoff
    constexpr double epsilon  = 0.15;   // kcal/mol — well depth
    constexpr double sigma    = 3.5;    // Angstroms — VdW radius
    constexpr double kappa    = 0.3;    // inverse Debye length (1/A)
    constexpr double coulomb  = 332.06; // kcal*A/(mol*e^2)
    constexpr double gamma    = 0.005;  // kcal/(mol*A^2) — desolvation

    for (size_t i = 0; i < DIM; ++i) {
        // Charge class: map to [-1, +1] range via (i%16 - 8)/8
        double q_i  = static_cast<double>(static_cast<int>(i % 16) - 8) / 8.0;
        // Size class: effective surface area ~ (i/16 + 1)^(2/3)
        double sa_i = std::pow(static_cast<double>(i / 16 + 1), 2.0 / 3.0);

        for (size_t j = i; j < DIM; ++j) {
            double q_j  = static_cast<double>(static_cast<int>(j % 16) - 8) / 8.0;
            double sa_j = std::pow(static_cast<double>(j / 16 + 1), 2.0 / 3.0);

            // Distance from index difference
            double r = std::abs(static_cast<double>(i) - static_cast<double>(j))
                       / 255.0 * (r_max - r_min) + r_min;

            // Lennard-Jones 12-6
            double sr6  = std::pow(sigma / r, 6.0);
            double e_lj = epsilon * (sr6 * sr6 - 2.0 * sr6);

            // Screened electrostatics (Debye-Huckel)
            double e_elec = coulomb * q_i * q_j * std::exp(-kappa * r) / r;

            // Desolvation penalty
            double e_desolv = gamma * (sa_i + sa_j);

            // Total pairwise energy
            double e_total = e_lj + e_elec + e_desolv;

            // Symmetric assignment
            matrix_[i][j] = e_total;
            matrix_[j][i] = e_total;
        }
    }
}

double ShannonEnergyMatrix::weighted_entropy(
    const double* probs, size_t n,
    const uint8_t* token_ids, size_t context_len
) const noexcept {
    if (n == 0 || context_len == 0) return 0.0;

    // Compute average interaction weight for each candidate token
    // based on its energy with the context tokens
    double H = 0.0;

    for (size_t i = 0; i < n; ++i) {
        if (probs[i] <= 0.0) continue;

        // Average energy of token i with context
        double w = 0.0;
        uint8_t ti = static_cast<uint8_t>(i % DIM);
        for (size_t c = 0; c < context_len; ++c) {
            w += matrix_[ti][token_ids[c]];
        }
        w /= static_cast<double>(context_len);

        // Boltzmann-inspired weight: exp(-beta * E) with beta=1
        double weight = std::exp(-w);
        H -= weight * probs[i] * std::log2(probs[i]);
    }

    return H;
}

size_t ShannonEnergyMatrix::nonzero_count() const noexcept {
    size_t count = 0;
    for (size_t i = 0; i < DIM; ++i) {
        for (size_t j = 0; j < DIM; ++j) {
            if (matrix_[i][j] != 0.0) ++count;
        }
    }
    return count;
}

}  // namespace shannon
