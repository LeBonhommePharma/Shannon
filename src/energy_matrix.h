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
