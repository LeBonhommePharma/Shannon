// =============================================================================
// ShannonEnergyMatrix — 256x256 White-Box Physicochemical Referee
//
// Ported from FlexAIDdS ShannonEnergyMatrix singleton + NaturalField.
//
// Initialization priority:
//   1. Load precomputed soft_contact_256.bin (production, from PDBbind training)
//   2. Fall back to closed-form LJ + Debye-Huckel + desolvation (development)
//
// The soft-contact binary blob uses the 8-bit type encoding:
//   Bits 0-4: base type (32), Bits 5-6: charge bin (4), Bit 7: H-bond (2)
//   Total: 256 types, 256x256 symmetric matrix, float32, 256 KB
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include "energy_matrix.h"
#include <cmath>
#include <cstring>
#include <fstream>
#include <numbers>

#ifdef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif

#ifdef SHANNON_HAS_AVX2
#ifndef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif
#endif

#ifdef SHANNON_HAS_OPENMP
#include <omp.h>
#endif

namespace shannon {

// =============================================================================
// SoftContactMatrix
// =============================================================================

SoftContactMatrix::SoftContactMatrix() {
    std::memset(data_, 0, sizeof(data_));
}

bool SoftContactMatrix::load(const char* path) {
    std::ifstream file(path, std::ios::binary);
    if (!file.is_open()) return false;

    // Read header: magic (4 bytes) + dimensions (2x uint16)
    char magic[4];
    file.read(magic, 4);
    if (magic[0] != 'S' || magic[1] != 'C' || magic[2] != '0' || magic[3] != '1') {
        return false;
    }

    uint16_t rows, cols;
    file.read(reinterpret_cast<char*>(&rows), sizeof(rows));
    file.read(reinterpret_cast<char*>(&cols), sizeof(cols));
    if (rows != DIM || cols != DIM) return false;

    // Read float32 data (row-major)
    file.read(reinterpret_cast<char*>(data_), sizeof(data_));
    if (!file.good()) return false;

    loaded_ = true;
    return true;
}

// =============================================================================
// ShannonEnergyMatrix — Singleton
// =============================================================================

const ShannonEnergyMatrix& ShannonEnergyMatrix::instance() {
    static ShannonEnergyMatrix inst;
    return inst;
}

ShannonEnergyMatrix::ShannonEnergyMatrix() {
    // Try loading from soft-contact binary blob first
    // Search common paths relative to typical install locations
    static const char* search_paths[] = {
        "data/soft_contact_256.bin",
        "../data/soft_contact_256.bin",
        "../../data/soft_contact_256.bin",
        nullptr
    };

    bool loaded = false;
    for (const char** p = search_paths; *p != nullptr; ++p) {
        if (soft_contact_.load(*p)) {
            load_from_soft_contact();
            source_ = "soft_contact";
            loaded = true;
            break;
        }
    }

    if (!loaded) {
        initialize_closed_form();
        source_ = "closed_form";
    }
}

void ShannonEnergyMatrix::load_from_soft_contact() {
    // Convert float32 soft-contact data to double64 matrix
    for (size_t i = 0; i < DIM; ++i) {
        for (size_t j = 0; j < DIM; ++j) {
            matrix_[i][j] = static_cast<double>(soft_contact_.lookup(
                static_cast<uint8_t>(i), static_cast<uint8_t>(j)));
        }
    }
}

void ShannonEnergyMatrix::initialize_closed_form() {
    // Closed-form physicochemical potential (development fallback):
    // E(i,j) = LJ(i,j) + Debye-Huckel(i,j) + desolvation(i,j)
    //
    // Uses the 8-bit type encoding to derive physical properties:
    //   base_type -> sigma (VdW radius), epsilon (well depth), surface area
    //   charge_bin -> partial charge q
    //   hbond_flag -> H-bond donor/acceptor bonus

    for (size_t i = 0; i < DIM; ++i) {
        auto ti = decode_type(static_cast<uint8_t>(i));

        // Physical properties from type encoding
        double sigma_i = 1.4 + (ti.base_type / 31.0) * 2.6;
        double eps_i   = 0.02 + (ti.base_type / 31.0) * 0.28;
        double q_i     = (ti.charge_bin == 0) ? -0.8 :
                         (ti.charge_bin == 1) ? -0.2 :
                         (ti.charge_bin == 2) ?  0.2 : 0.8;
        double sa_i    = 4.0 * std::numbers::pi * sigma_i * sigma_i;

        for (size_t j = i; j < DIM; ++j) {
            auto tj = decode_type(static_cast<uint8_t>(j));

            double sigma_j = 1.4 + (tj.base_type / 31.0) * 2.6;
            double eps_j   = 0.02 + (tj.base_type / 31.0) * 0.28;
            double q_j     = (tj.charge_bin == 0) ? -0.8 :
                             (tj.charge_bin == 1) ? -0.2 :
                             (tj.charge_bin == 2) ?  0.2 : 0.8;
            double sa_j    = 4.0 * std::numbers::pi * sigma_j * sigma_j;

            // Lorentz-Berthelot combining rules
            double sigma_ij = (sigma_i + sigma_j) / 2.0;
            double eps_ij   = std::sqrt(eps_i * eps_j);
            double r_ij     = sigma_ij * 1.122;  // ~2^(1/6) equilibrium

            // H-bond bonus: attractive when donor meets acceptor
            double hbond_bonus = (ti.hbond != tj.hbond) ? -0.5 : 0.0;

            // 1. Lennard-Jones 12-6
            double sr6  = std::pow(sigma_ij / r_ij, 6.0);
            double e_lj = eps_ij * (sr6 * sr6 - 2.0 * sr6);

            // 2. Screened electrostatics (Debye-Huckel)
            constexpr double kappa   = 0.3;
            constexpr double coulomb = 332.06;
            double e_elec = coulomb * q_i * q_j * std::exp(-kappa * r_ij) / r_ij;

            // 3. Desolvation penalty
            constexpr double gamma = 0.005;
            double e_desolv = gamma * (sa_i + sa_j);

            double e_total = e_lj + e_elec + e_desolv + hbond_bonus;

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

    double H = 0.0;
    const double inv_context = 1.0 / static_cast<double>(context_len);

#ifdef SHANNON_HAS_OPENMP
    if (n > 10000) {
        #pragma omp parallel for reduction(-:H)
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] <= 0.0) continue;
            double w = 0.0;
            uint8_t ti = static_cast<uint8_t>(i % DIM);
            for (size_t c = 0; c < context_len; ++c) {
                w += matrix_[ti][token_ids[c]];
            }
            w *= inv_context;
            double weight = std::exp(-w);
            H -= weight * probs[i] * std::log2(probs[i]);
        }
    } else
#endif
    {
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] <= 0.0) continue;
            double w = 0.0;
            uint8_t ti = static_cast<uint8_t>(i % DIM);
            for (size_t c = 0; c < context_len; ++c) {
                w += matrix_[ti][token_ids[c]];
            }
            w *= inv_context;
            double weight = std::exp(-w);
            H -= weight * probs[i] * std::log2(probs[i]);
        }
    }

    return H;
}

double ShannonEnergyMatrix::weighted_entropy_with_bias(
    const double* probs, size_t n,
    const uint8_t* token_ids, size_t context_len,
    const SuperCluster& cluster,
    double bias_sigma
) const noexcept {
    if (n == 0 || context_len == 0 || cluster.centroid.empty()) return 0.0;

    const double inv_context = 1.0 / static_cast<double>(context_len);
    const double inv_2sigma2 = 1.0 / (2.0 * bias_sigma * bias_sigma);
    const size_t centroid_dim = std::min(cluster.centroid.size(), static_cast<size_t>(DIM));
    double H = 0.0;

#ifdef SHANNON_HAS_OPENMP
    if (n > 10000) {
        #pragma omp parallel for reduction(-:H)
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] <= 0.0) continue;
            uint8_t ti = static_cast<uint8_t>(i % DIM);

            double w = 0.0;
            for (size_t c = 0; c < context_len; ++c) {
                w += matrix_[ti][token_ids[c]];
            }
            w *= inv_context;

            double dist_sq = 0.0;
            for (size_t k = 0; k < centroid_dim; ++k) {
                double diff = matrix_[ti][k] - static_cast<double>(cluster.centroid[k]);
                dist_sq += diff * diff;
            }
            double gaussian_bias = std::exp(-dist_sq * inv_2sigma2);
            double weight = std::exp(-w) * gaussian_bias;
            H -= weight * probs[i] * std::log2(probs[i]);
        }
    } else
#endif
    {
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] <= 0.0) continue;
            uint8_t ti = static_cast<uint8_t>(i % DIM);

            double w = 0.0;
            for (size_t c = 0; c < context_len; ++c) {
                w += matrix_[ti][token_ids[c]];
            }
            w *= inv_context;

            double dist_sq = 0.0;
            for (size_t k = 0; k < centroid_dim; ++k) {
                double diff = matrix_[ti][k] - static_cast<double>(cluster.centroid[k]);
                dist_sq += diff * diff;
            }
            double gaussian_bias = std::exp(-dist_sq * inv_2sigma2);
            double weight = std::exp(-w) * gaussian_bias;
            H -= weight * probs[i] * std::log2(probs[i]);
        }
    }

    return H;
}

std::vector<float> ShannonEnergyMatrix::get_row_vector(uint8_t type_i) const {
    std::vector<float> row(DIM);
    for (size_t j = 0; j < DIM; ++j) {
        row[j] = static_cast<float>(matrix_[type_i][j]);
    }
    return row;
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
