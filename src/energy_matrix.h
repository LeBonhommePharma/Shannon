#pragma once
// =============================================================================
// ShannonEnergyMatrix — 256x256 White-Box Physicochemical Referee
//
// Ported from FlexAIDdS ShannonEnergyMatrix singleton + NaturalField.
// 65,536 precomputed energy parameters for token-pair interaction weighting.
// Every parameter is a known physicochemical quantity — fully auditable.
//
// The matrix uses an 8-bit type encoding:
//   Bits 0-4: Base atom/concept type (element + hybridization)  [32 types]
//   Bits 5-6: Partial charge bin (strong-, weak-, weak+, strong+) [4 states]
//   Bit    7: H-bond donor/acceptor flag                         [2 states]
//   Total: 32 x 4 x 2 = 256 types
//
// Storage: alignas(64) float[256*256] = 256 KB, fits in L1 cache.
// Lookup: O(1), integer-indexed, no hashing, no tree traversal.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <array>
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <string>
#include <vector>

namespace shannon {

// =============================================================================
// SoftContactMatrix — Low-level L1-resident 256x256 energy table
// Ported from FlexAIDdS NaturalField::getSoftContact(i,j)
// =============================================================================

class SoftContactMatrix {
public:
    static constexpr size_t DIM = 256;
    static constexpr size_t TOTAL_ENTRIES = DIM * DIM;  // 65,536
    static constexpr size_t BYTE_SIZE = TOTAL_ENTRIES * sizeof(float);  // 256 KB

    SoftContactMatrix();

    // Load from binary blob (SC01 format: 4-byte magic + 2x uint16 dims + float32 data)
    bool load(const char* path);

    // O(1) lookup — symmetric: data[i*256+j] == data[j*256+i]
    float lookup(uint8_t type_i, uint8_t type_j) const noexcept {
        return data_[static_cast<unsigned>(type_i) * DIM + type_j];
    }

    // Raw row access for SIMD bulk operations
    const float* row(uint8_t type_i) const noexcept {
        return &data_[static_cast<unsigned>(type_i) * DIM];
    }

    // Raw data access
    const float* data() const noexcept { return data_; }

    bool is_loaded() const noexcept { return loaded_; }

    // Batch lookup: score N type-pairs in one call (AVX2/AVX-512 accelerated)
    // types_i[k], types_j[k] → scores[k] = data_[types_i[k] * 256 + types_j[k]]
    void batch_lookup(const uint8_t* types_i, const uint8_t* types_j,
                      float* scores, size_t n) const noexcept;

    // Row-dot: dot product of matrix row with a 256-d weight vector (FMA accelerated)
    float row_dot(uint8_t type_i, const float* weights) const noexcept;

private:
    alignas(64) float data_[TOTAL_ENTRIES];  // 256 KB, L1-resident
    bool loaded_ = false;
};

// =============================================================================
// MatrixConfig — Configuration for matrix loading and fallback
// =============================================================================

struct MatrixConfig {
    std::string blob_path;         // Path to soft_contact_256.bin
    bool allow_closed_form = true; // Fall back to closed-form if blob missing
};

// =============================================================================
// 8-bit type encoding helpers
// =============================================================================

struct TypeInfo {
    uint8_t type_index;
    uint8_t base_type;     // bits 0-4: element + hybridization (0-31)
    uint8_t charge_bin;    // bits 5-6: partial charge (0-3)
    bool    hbond;         // bit 7: H-bond donor/acceptor
};

inline TypeInfo decode_type(uint8_t t) noexcept {
    return TypeInfo{
        t,
        static_cast<uint8_t>(t & 0x1F),
        static_cast<uint8_t>((t >> 5) & 0x03),
        static_cast<bool>((t >> 7) & 0x01)
    };
}

inline uint8_t encode_type(uint8_t base, uint8_t charge, bool hbond) noexcept {
    return (base & 0x1F)
         | ((charge & 0x03) << 5)
         | (static_cast<uint8_t>(hbond) << 7);
}

// =============================================================================
// SuperCluster — Result of FastOPTICS clustering on matrix row activations
// =============================================================================

struct SuperCluster {
    std::vector<uint8_t> member_types;    // Type indices in this cluster
    std::vector<float> centroid;          // 256-d centroid vector
    float radius;                         // Cluster radius
    size_t cluster_id;
};

// =============================================================================
// SYBYL Bridge — map between 32 base types and ~40 SYBYL atom types
// =============================================================================

// Map SYBYL atom type string to base type (0-31). Returns -1 for unknown.
int sybyl_to_base(const char* sybyl_type) noexcept;

// Map base type (0-31) back to SYBYL parent index (0-39).
int base_to_sybyl_parent(uint8_t base_type) noexcept;

// Project 256×256 matrix to 40×40 SYBYL-equivalent (block-mean).
// out_40x40 must point to at least 32*32 = 1024 floats.
void project_to_40x40(const SoftContactMatrix& matrix, float* out_40x40) noexcept;

// =============================================================================
// ScoringResult — Output of two-stage pose scoring
// =============================================================================

struct ScoringResult {
    double entropy;           // Shannon entropy of surviving pose ensemble
    size_t poses_evaluated;   // Number surviving pre-filter
    size_t poses_total;       // Total input poses
    double delta_g_proxy;     // Boltzmann-weighted ΔG estimate
};

// =============================================================================
// ShannonEnergyMatrix — Main API (256x256 white-box referee)
// =============================================================================

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

    // Weighted entropy with Gaussian bias from super-cluster centroid
    // Applied after collapse detection: modulates entropy by proximity to cluster
    double weighted_entropy_with_bias(
        const double* probs, size_t n,
        const uint8_t* token_ids, size_t context_len,
        const SuperCluster& cluster,
        double bias_sigma = 2.0) const noexcept;

    // Interaction score between two token distributions
    double interaction_score(uint8_t token_a, uint8_t token_b) const noexcept {
        return matrix_[token_a][token_b];
    }

    // Get active row vector for a token type (for clustering)
    std::vector<float> get_row_vector(uint8_t type_i) const;

    // Number of non-zero parameters (sparsity check)
    size_t nonzero_count() const noexcept;

    // Access underlying SoftContactMatrix
    const SoftContactMatrix& soft_contact() const noexcept { return soft_contact_; }

    // Two-stage pose scoring:
    // 1. Matrix pre-filter: fast O(1) lookup, eliminate ~90% of poses
    // 2. Analytic refinement: full LJ+Coulomb on survivors
    // Returns Boltzmann-weighted entropy over surviving poses
    ScoringResult score_poses_two_stage(
        const uint8_t* pose_types_i,   // [n_poses * contacts_per_pose]
        const uint8_t* pose_types_j,   // [n_poses * contacts_per_pose]
        const float* distances,        // [n_poses * contacts_per_pose]
        size_t n_poses,
        size_t contacts_per_pose,
        float cutoff_percentile = 0.10f  // keep top 10%
    ) const noexcept;

    // Source of matrix data
    const char* source() const noexcept { return source_; }

    ShannonEnergyMatrix(const ShannonEnergyMatrix&) = delete;
    ShannonEnergyMatrix& operator=(const ShannonEnergyMatrix&) = delete;

private:
    ShannonEnergyMatrix();
    void initialize_closed_form();
    void load_from_soft_contact();

    std::array<std::array<double, DIM>, DIM> matrix_;
    SoftContactMatrix soft_contact_;
    const char* source_ = "closed_form";
};

}  // namespace shannon
