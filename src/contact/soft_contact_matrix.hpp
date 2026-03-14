// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// 256×256 Soft Contact Interaction Matrix
// Direct upgrade of FlexAID's 40×40 CF matrix at force-field resolution.
//
// The matrix stores precomputed interaction energies indexed by 8-bit atom
// types.  At runtime, scoring a contact is a single array lookup:
//
//   energy += matrix.lookup(type_i, type_j);
//
// Memory: 256 × 256 × 4 bytes = 256 KB (fits in L2 cache).
// Indexing: uint8_t × 256 + uint8_t = single multiply + add.
//
// Binary format (SCM1): little-endian, platform-specific.
// Files are NOT portable across architectures with different endianness.

#pragma once

#include "atom_types.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace shannon::contact {

// ─── Constants ──────────────────────────────────────────────────────────────

inline constexpr std::size_t kNumAtomTypes = 256;
inline constexpr std::size_t kMatrixSize   = kNumAtomTypes * kNumAtomTypes;  // 65536
inline constexpr std::size_t kMatrixBytes  = kMatrixSize * sizeof(float);    // 262144

// Optional file header: magic "SCM1" + uint32 version + uint64 reserved
inline constexpr char     kMagic[4]        = {'S', 'C', 'M', '1'};
inline constexpr uint32_t kVersion         = 1;
inline constexpr std::size_t kHeaderBytes  = 16;  // 4 + 4 + 8

// ─── Contact Pair ───────────────────────────────────────────────────────────

/// A single atom-atom contact for pose activation computation.
struct ContactPair {
    std::uint8_t type_i;
    std::uint8_t type_j;
    float        weight;   ///< distance-dependent weight (e.g., Gaussian cutoff)
};

// ─── SoftContactMatrix ─────────────────────────────────────────────────────

class SoftContactMatrix {
public:
    /// Construct a zero-initialized matrix.
    SoftContactMatrix();

    /// Load from a binary file (raw 256 KB or with 16-byte SCM1 header).
    void load(const char* path);
    void load(const std::string& path) { load(path.c_str()); }

    /// Load from a memory buffer of kMatrixSize floats.
    void load_from_buffer(const float* src);

    /// Save to a binary file (with SCM1 header).
    void save(const char* path) const;
    void save(const std::string& path) const { save(path.c_str()); }

    /// O(1) lookup — the core scoring primitive.
    float lookup(std::uint8_t type_i, std::uint8_t type_j) const noexcept {
        return data_[static_cast<std::size_t>(type_i) * kNumAtomTypes + type_j];
    }

    /// Mutable access for training / population.
    float& at(std::uint8_t type_i, std::uint8_t type_j) noexcept {
        return data_[static_cast<std::size_t>(type_i) * kNumAtomTypes + type_j];
    }

    /// Raw data access.
    const float* data() const noexcept { return data_; }
    float*       data()       noexcept { return data_; }

    /// Enforce symmetry: M[i][j] = M[j][i] = (M[i][j] + M[j][i]) / 2.
    void symmetrize() noexcept;

    /// Check if the matrix is symmetric within tolerance.
    bool is_symmetric(float tol = 1e-6f) const noexcept;

    /// Compute a 256-dimensional pose activation vector.
    /// For each atom type t, sums the weighted matrix contributions from
    /// all contacts involving that type.
    ///
    /// @param contacts   array of ContactPair
    /// @param n_contacts number of contacts
    /// @param out        output array of kNumAtomTypes (256) floats, zeroed first
    void pose_activation(
        const ContactPair* __restrict contacts,
        std::size_t                   n_contacts,
        float* __restrict             out
    ) const;

    /// Score from separate type/weight arrays (avoids ContactPair overhead).
    float score_contacts_arrays(
        const std::uint8_t* __restrict types_i,
        const std::uint8_t* __restrict types_j,
        const float* __restrict        weights,
        std::size_t                    n_contacts
    ) const noexcept;

    /// Pose activation from separate type/weight arrays.
    void pose_activation_arrays(
        const std::uint8_t* __restrict types_i,
        const std::uint8_t* __restrict types_j,
        const float* __restrict        weights,
        std::size_t                    n_contacts,
        float* __restrict              out
    ) const;

    /// Score a full set of contacts: sum of matrix lookups × weights.
    float score_contacts(
        const ContactPair* __restrict contacts,
        std::size_t                   n_contacts
    ) const noexcept;

    /// Project the 256×256 matrix down to a coarse n×n matrix grouped
    /// by SYBYL parent type (base type, bits 0–4).  Each cell in the
    /// output is the mean of the corresponding block in the 256×256.
    ///
    /// This validates consistency with FlexAID's 40×40 CF matrix.
    ///
    /// @param out        output array of n_sybyl × n_sybyl floats
    /// @param n_sybyl    number of SYBYL types (default kNumSybylTypes = 32)
    void project_to_sybyl(
        float* __restrict out,
        std::size_t       n_sybyl = kNumSybylTypes
    ) const;

    /// Batch scoring: score multiple contact sets efficiently.
    /// Uses OpenMP parallel for across independent sets.
    void score_batch(
        const ContactPair* const* __restrict contact_sets,
        const std::size_t* __restrict        set_sizes,
        std::size_t                          n_sets,
        float* __restrict                    scores
    ) const noexcept;

private:
    alignas(64) float data_[kMatrixSize];  // 256 KB, cache-line aligned
};

}  // namespace shannon::contact
