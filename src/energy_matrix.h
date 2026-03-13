#pragma once
// =============================================================================
// ShannonEnergyMatrix — 256x256 White-Box Physicochemical Referee
//
// Ported from FlexAIDdS ShannonEnergyMatrix singleton.
// 65,536 precomputed energy parameters for token-pair interaction weighting.
// Every parameter is a known physicochemical quantity — fully auditable.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <array>
#include <cstddef>
#include <cstdint>
#include <cmath>

namespace shannon {

class ShannonEnergyMatrix {
public:
    static constexpr size_t DIM = 256;
    static constexpr size_t TOTAL_PARAMS = DIM * DIM;  // 65,536

    // Singleton access (thread-safe via static local)
    static const ShannonEnergyMatrix& instance();

    // O(1) energy lookup — symmetric: E[i][j] == E[j][i]
    double energy(uint8_t i, uint8_t j) const noexcept {
        return matrix_[i][j];
    }

    // Raw access for SIMD bulk operations
    const double* row(uint8_t i) const noexcept {
        return matrix_[i].data();
    }

    // Weighted entropy: H_w = -sum_i (w_i * p_i * log2(p_i))
    // where w_i incorporates energy-matrix context from token neighborhood
    double weighted_entropy(const double* probs, size_t n,
                            const uint8_t* token_ids, size_t context_len) const noexcept;

    // Interaction score between two token distributions
    double interaction_score(uint8_t token_a, uint8_t token_b) const noexcept {
        return matrix_[token_a][token_b];
    }

    // Number of non-zero parameters (sparsity check)
    size_t nonzero_count() const noexcept;

    ShannonEnergyMatrix(const ShannonEnergyMatrix&) = delete;
    ShannonEnergyMatrix& operator=(const ShannonEnergyMatrix&) = delete;

private:
    ShannonEnergyMatrix();
    void initialize();

    std::array<std::array<double, DIM>, DIM> matrix_;
};

}  // namespace shannon
