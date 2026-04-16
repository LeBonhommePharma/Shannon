// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// 256×256 Soft Contact Matrix — implementation.
//
// NOTE (reproducibility): OpenMP reductions (+:) over floating-point
// may produce different bit-level results with different thread counts.
// Set OMP_NUM_THREADS=1 for bitwise-reproducible results across runs.

#include "soft_contact_matrix.hpp"

#include <cstdio>
#include <cstring>

namespace shannon::contact {

// ─── Construction ───────────────────────────────────────────────────────────

SoftContactMatrix::SoftContactMatrix() {
    std::memset(data_, 0, kMatrixBytes);
}

// ─── File I/O ───────────────────────────────────────────────────────────────

void SoftContactMatrix::load(const char* path) {
    FILE* fp = std::fopen(path, "rb");
    if (!fp) {
        throw std::runtime_error(
            std::string("SoftContactMatrix::load: cannot open '") + path + "'");
    }

    // Determine file size
    std::fseek(fp, 0, SEEK_END);
    const long file_size = std::ftell(fp);
    std::fseek(fp, 0, SEEK_SET);

    if (file_size == static_cast<long>(kHeaderBytes + kMatrixBytes)) {
        // File with SCM1 header
        char magic[4];
        uint32_t version;
        uint64_t reserved;

        if (std::fread(magic, 1, 4, fp) != 4 ||
            std::fread(&version, sizeof(version), 1, fp) != 1 ||
            std::fread(&reserved, sizeof(reserved), 1, fp) != 1) {
            std::fclose(fp);
            throw std::runtime_error(
                "SoftContactMatrix::load: failed to read header");
        }

        if (std::memcmp(magic, kMagic, 4) != 0) {
            std::fclose(fp);
            throw std::runtime_error(
                "SoftContactMatrix::load: invalid magic bytes");
        }
    } else if (file_size != static_cast<long>(kMatrixBytes)) {
        std::fclose(fp);
        throw std::runtime_error(
            "SoftContactMatrix::load: unexpected file size " +
            std::to_string(file_size) + " (expected " +
            std::to_string(kMatrixBytes) + " or " +
            std::to_string(kHeaderBytes + kMatrixBytes) + ")");
    }

    const std::size_t read = std::fread(data_, sizeof(float), kMatrixSize, fp);
    std::fclose(fp);

    if (read != kMatrixSize) {
        throw std::runtime_error(
            "SoftContactMatrix::load: incomplete read (" +
            std::to_string(read) + " / " + std::to_string(kMatrixSize) +
            " floats)");
    }
}

void SoftContactMatrix::load_from_buffer(const float* src) {
    std::memcpy(data_, src, kMatrixBytes);
}

void SoftContactMatrix::save(const char* path) const {
    FILE* fp = std::fopen(path, "wb");
    if (!fp) {
        throw std::runtime_error(
            std::string("SoftContactMatrix::save: cannot open '") + path + "'");
    }

    // Write header
    std::fwrite(kMagic, 1, 4, fp);
    std::fwrite(&kVersion, sizeof(kVersion), 1, fp);
    const uint64_t reserved = 0;
    std::fwrite(&reserved, sizeof(reserved), 1, fp);

    // Write matrix data
    const std::size_t written = std::fwrite(data_, sizeof(float), kMatrixSize, fp);
    std::fclose(fp);

    if (written != kMatrixSize) {
        throw std::runtime_error(
            "SoftContactMatrix::save: incomplete write (" +
            std::to_string(written) + " / " + std::to_string(kMatrixSize) +
            " floats)");
    }
}

// ─── Symmetry ───────────────────────────────────────────────────────────────

void SoftContactMatrix::symmetrize() noexcept {
    for (std::size_t i = 0; i < kNumAtomTypes; ++i) {
        for (std::size_t j = i + 1; j < kNumAtomTypes; ++j) {
            const float avg = (data_[i * kNumAtomTypes + j] +
                               data_[j * kNumAtomTypes + i]) * 0.5f;
            data_[i * kNumAtomTypes + j] = avg;
            data_[j * kNumAtomTypes + i] = avg;
        }
    }
}

bool SoftContactMatrix::is_symmetric(float tol) const noexcept {
    for (std::size_t i = 0; i < kNumAtomTypes; ++i) {
        for (std::size_t j = i + 1; j < kNumAtomTypes; ++j) {
            const float diff = data_[i * kNumAtomTypes + j] -
                               data_[j * kNumAtomTypes + i];
            if (diff > tol || diff < -tol) return false;
        }
    }
    return true;
}

// ─── Pose Activation ────────────────────────────────────────────────────────

void SoftContactMatrix::pose_activation(
    const ContactPair* __restrict contacts,
    std::size_t                   n_contacts,
    float* __restrict             out
) const {
    std::memset(out, 0, kNumAtomTypes * sizeof(float));

    for (std::size_t c = 0; c < n_contacts; ++c) {
        const auto& cp = contacts[c];
        const float val = lookup(cp.type_i, cp.type_j) * cp.weight;
        out[cp.type_i] += val;
        out[cp.type_j] += val;
    }
}

void SoftContactMatrix::pose_activation_arrays(
    const std::uint8_t* __restrict types_i,
    const std::uint8_t* __restrict types_j,
    const float* __restrict        weights,
    std::size_t                    n_contacts,
    float* __restrict              out
) const {
    std::memset(out, 0, kNumAtomTypes * sizeof(float));

    for (std::size_t c = 0; c < n_contacts; ++c) {
        const float val = data_[static_cast<std::size_t>(types_i[c]) * kNumAtomTypes
                                + types_j[c]] * weights[c];
        out[types_i[c]] += val;
        out[types_j[c]] += val;
    }
}

// ─── Contact Scoring ────────────────────────────────────────────────────────

float SoftContactMatrix::score_contacts(
    const ContactPair* __restrict contacts,
    std::size_t                   n_contacts
) const noexcept {
    float total = 0.0f;

    #pragma omp simd reduction(+:total)
    for (std::size_t c = 0; c < n_contacts; ++c) {
        total += data_[static_cast<std::size_t>(contacts[c].type_i) * kNumAtomTypes
                       + contacts[c].type_j] * contacts[c].weight;
    }

    return total;
}

float SoftContactMatrix::score_contacts_arrays(
    const std::uint8_t* __restrict types_i,
    const std::uint8_t* __restrict types_j,
    const float* __restrict        weights,
    std::size_t                    n_contacts
) const noexcept {
    float total = 0.0f;

    #pragma omp simd reduction(+:total)
    for (std::size_t c = 0; c < n_contacts; ++c) {
        total += data_[static_cast<std::size_t>(types_i[c]) * kNumAtomTypes
                       + types_j[c]] * weights[c];
    }

    return total;
}

// ─── SYBYL Projection ───────────────────────────────────────────────────────

void SoftContactMatrix::project_to_sybyl(
    float* __restrict out,
    std::size_t       n_sybyl
) const {
    const std::size_t out_size = n_sybyl * n_sybyl;
    std::memset(out, 0, out_size * sizeof(float));
    std::vector<int> counts(out_size, 0);

    for (std::size_t i = 0; i < kNumAtomTypes; ++i) {
        const std::size_t si = sybyl_parent(static_cast<std::uint8_t>(i));
        if (si >= n_sybyl) continue;

        for (std::size_t j = 0; j < kNumAtomTypes; ++j) {
            const std::size_t sj = sybyl_parent(static_cast<std::uint8_t>(j));
            if (sj >= n_sybyl) continue;

            const std::size_t out_idx = si * n_sybyl + sj;
            out[out_idx] += data_[i * kNumAtomTypes + j];
            counts[out_idx]++;
        }
    }

    for (std::size_t k = 0; k < out_size; ++k) {
        if (counts[k] > 0) {
            out[k] /= static_cast<float>(counts[k]);
        }
    }
}

// ─── Batch Scoring ──────────────────────────────────────────────────────────

void SoftContactMatrix::score_batch(
    const ContactPair* const* __restrict contact_sets,
    const std::size_t* __restrict        set_sizes,
    std::size_t                          n_sets,
    float* __restrict                    scores
) const noexcept {
    #pragma omp parallel for schedule(static)
    for (std::size_t s = 0; s < n_sets; ++s) {
        scores[s] = score_contacts(contact_sets[s], set_sizes[s]);
    }
}

}  // namespace shannon::contact
