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
#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <numbers>
#include <numeric>

// Prefer SHANNON_USE_* (set by CMake); accept SHANNON_HAS_* as aliases.
#if defined(SHANNON_USE_AVX512) && !defined(SHANNON_HAS_AVX512)
#  define SHANNON_HAS_AVX512 1
#endif
#if defined(SHANNON_USE_AVX2) && !defined(SHANNON_HAS_AVX2)
#  define SHANNON_HAS_AVX2 1
#endif
#if defined(SHANNON_USE_OPENMP) && !defined(SHANNON_HAS_OPENMP)
#  define SHANNON_HAS_OPENMP 1
#endif
#if defined(SHANNON_USE_NEON) && !defined(SHANNON_HAS_NEON)
#  define SHANNON_HAS_NEON 1
#endif

#ifdef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif

#ifdef SHANNON_HAS_AVX2
#ifndef SHANNON_HAS_AVX512
#include <immintrin.h>
#endif
#endif

#if defined(SHANNON_HAS_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
#include <arm_neon.h>
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
        #pragma omp parallel for reduction(+:H)
        for (size_t i = 0; i < n; ++i) {
            if (probs[i] <= 0.0) continue;
            double w = 0.0;
            uint8_t ti = static_cast<uint8_t>(i % DIM);
            for (size_t c = 0; c < context_len; ++c) {
                w += matrix_[ti][token_ids[c]];
            }
            w *= inv_context;
            double weight = std::exp(-w);
            H += weight * (-probs[i] * std::log2(probs[i]));
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
            H += weight * (-probs[i] * std::log2(probs[i]));
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
        #pragma omp parallel for reduction(+:H)
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
            H += weight * (-probs[i] * std::log2(probs[i]));
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
            H += weight * (-probs[i] * std::log2(probs[i]));
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

// =============================================================================
// SoftContactMatrix — Batch Lookup (AVX2/AVX-512 accelerated)
// =============================================================================

void SoftContactMatrix::batch_lookup(
    const uint8_t* types_i, const uint8_t* types_j,
    float* scores, size_t n
) const noexcept {
    if (n == 0 || !types_i || !types_j || !scores) return;
    size_t k = 0;

#ifdef SHANNON_HAS_AVX512
    // 16 float32 lookups per cycle via _mm512_i32gather_ps
    for (; k + 16 <= n; k += 16) {
        alignas(64) int32_t indices[16];
        for (int m = 0; m < 16; ++m) {
            indices[m] = static_cast<int32_t>(types_i[k + m]) * 256
                       + static_cast<int32_t>(types_j[k + m]);
        }
        __m512i idx = _mm512_load_epi32(indices);
        __m512 vals = _mm512_i32gather_ps(idx, data_, 4);
        _mm512_storeu_ps(scores + k, vals);
    }
#endif

#ifdef SHANNON_HAS_AVX2
    // 8 float32 lookups per cycle via _mm256_i32gather_ps
    for (; k + 8 <= n; k += 8) {
        alignas(32) int32_t indices[8];
        for (int m = 0; m < 8; ++m) {
            indices[m] = static_cast<int32_t>(types_i[k + m]) * 256
                       + static_cast<int32_t>(types_j[k + m]);
        }
        __m256i idx = _mm256_load_si256(reinterpret_cast<const __m256i*>(indices));
        __m256 vals = _mm256_i32gather_ps(data_, idx, 4);
        _mm256_storeu_ps(scores + k, vals);
    }
#endif

#if defined(SHANNON_HAS_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
    // NEON has no gather; compute 4 indices then scalar-load into a vector store.
    // Still faster than pure scalar due to better ILP and store coalescing.
    for (; k + 4 <= n; k += 4) {
        alignas(16) float vals[4];
        for (int m = 0; m < 4; ++m) {
            vals[m] = data_[static_cast<unsigned>(types_i[k + m]) * DIM
                            + types_j[k + m]];
        }
        vst1q_f32(scores + k, vld1q_f32(vals));
    }
#endif

    // Scalar tail
    for (; k < n; ++k) {
        scores[k] = data_[static_cast<unsigned>(types_i[k]) * DIM + types_j[k]];
    }
}

// =============================================================================
// SoftContactMatrix — Row-Dot (FMA accelerated)
// =============================================================================

float SoftContactMatrix::row_dot(uint8_t type_i, const float* weights) const noexcept {
    if (!weights) return 0.0f;
    const float* r = row(type_i);
    size_t j = 0;

#ifdef SHANNON_HAS_AVX512
    __m512 acc512 = _mm512_setzero_ps();
    for (; j + 16 <= DIM; j += 16) {
        __m512 rv = _mm512_loadu_ps(r + j);
        __m512 wv = _mm512_loadu_ps(weights + j);
        acc512 = _mm512_fmadd_ps(rv, wv, acc512);
    }
    float sum = _mm512_reduce_add_ps(acc512);
#elif defined(SHANNON_HAS_AVX2)
    __m256 acc0 = _mm256_setzero_ps();
    __m256 acc1 = _mm256_setzero_ps();
    for (; j + 16 <= DIM; j += 16) {
        __m256 rv0 = _mm256_loadu_ps(r + j);
        __m256 wv0 = _mm256_loadu_ps(weights + j);
        acc0 = _mm256_fmadd_ps(rv0, wv0, acc0);
        __m256 rv1 = _mm256_loadu_ps(r + j + 8);
        __m256 wv1 = _mm256_loadu_ps(weights + j + 8);
        acc1 = _mm256_fmadd_ps(rv1, wv1, acc1);
    }
    acc0 = _mm256_add_ps(acc0, acc1);
    // Horizontal sum of 8 floats
    __m128 hi = _mm256_extractf128_ps(acc0, 1);
    __m128 lo = _mm256_castps256_ps128(acc0);
    __m128 sum128 = _mm_add_ps(lo, hi);
    sum128 = _mm_hadd_ps(sum128, sum128);
    sum128 = _mm_hadd_ps(sum128, sum128);
    float sum = _mm_cvtss_f32(sum128);
#elif defined(SHANNON_HAS_NEON) && (defined(__ARM_NEON) || defined(__aarch64__))
    float32x4_t acc0 = vdupq_n_f32(0.0f);
    float32x4_t acc1 = vdupq_n_f32(0.0f);
    for (; j + 8 <= DIM; j += 8) {
        acc0 = vfmaq_f32(acc0, vld1q_f32(r + j),     vld1q_f32(weights + j));
        acc1 = vfmaq_f32(acc1, vld1q_f32(r + j + 4), vld1q_f32(weights + j + 4));
    }
    acc0 = vaddq_f32(acc0, acc1);
    float32x2_t s2 = vadd_f32(vget_low_f32(acc0), vget_high_f32(acc0));
    float sum = vget_lane_f32(vpadd_f32(s2, s2), 0);
#else
    float sum = 0.0f;
#endif

    // Scalar tail
    for (; j < DIM; ++j) {
        sum += r[j] * weights[j];
    }

    return sum;
}

// =============================================================================
// SYBYL Bridge
// =============================================================================

struct SybylEntry {
    const char* name;
    int base_type;
};

static const SybylEntry SYBYL_TABLE[] = {
    {"C.3",    0}, {"C.2",    1}, {"C.1",    2}, {"C.ar",   3}, {"C.cat",  4},
    {"N.3",    5}, {"N.2",    6}, {"N.1",    7}, {"N.ar",   8}, {"N.am",   9},
    {"N.pl3", 10}, {"N.4",   11},
    {"O.3",   12}, {"O.2",   13}, {"O.co2", 14}, {"O.spc", 12}, {"O.t3p", 12},
    {"S.3",   15}, {"S.2",   16}, {"S.O",   17}, {"S.O2",  17},
    {"P.3",   18},
    {"H",     19}, {"H.spc", 19}, {"H.t3p", 19},
    {"C.ar.het",   20}, {"C.2.bridge", 21},
    {"F",     22}, {"Cl",    23}, {"Br",    24}, {"I",     25},
    {"Zn",    26}, {"Fe",    27}, {"Mg",    28}, {"Ca",    29},
    {"Mn",    28}, {"Cu",    26}, {"Co",    27},
    {"Si",    30}, {"Du",    31}, {"LP",    31}, {"Any",   31},
};

static constexpr size_t SYBYL_TABLE_SIZE = sizeof(SYBYL_TABLE) / sizeof(SYBYL_TABLE[0]);

int sybyl_to_base(const char* sybyl_type) noexcept {
    if (!sybyl_type) return -1;
    for (size_t i = 0; i < SYBYL_TABLE_SIZE; ++i) {
        // Simple string comparison (SYBYL types are short)
        const char* a = sybyl_type;
        const char* b = SYBYL_TABLE[i].name;
        while (*a && *b && *a == *b) { ++a; ++b; }
        if (*a == '\0' && *b == '\0') {
            return SYBYL_TABLE[i].base_type;
        }
    }
    return -1;
}

// Maps base types (0-31) → SYBYL parent indices (0-39)
static constexpr int BASE_TO_SYBYL[] = {
     0,  1,  2,  3,  4,         // C.3, C.2, C.1, C.ar, C.cat
     5,  6,  7,  8,  9, 10, 11, // N.3..N.4
    12, 13, 14,                  // O.3, O.2, O.co2
    15, 16, 17,                  // S.3, S.2, S.O
    18,                          // P.3
    19,                          // H
     3,  1,                      // C.ar.het→C.ar, C.2.bridge→C.2
    20, 21, 22, 23,              // F, Cl, Br, I
    24, 25, 26, 27,              // Zn, Fe, Mg, Ca
    28, 29,                      // Si, Du
};

int base_to_sybyl_parent(uint8_t base_type) noexcept {
    if (base_type < 32) return BASE_TO_SYBYL[base_type];
    return 29;  // dummy
}

void project_to_40x40(const SoftContactMatrix& matrix, float* out_40x40) noexcept {
    constexpr size_t N_SYBYL = 32;

    float accum[N_SYBYL * N_SYBYL] = {};
    int   counts[N_SYBYL * N_SYBYL] = {};

    for (size_t i = 0; i < 256; ++i) {
        auto ti = decode_type(static_cast<uint8_t>(i));
        int si = base_to_sybyl_parent(ti.base_type);
        if (si < 0 || static_cast<size_t>(si) >= N_SYBYL) continue;

        for (size_t j = 0; j < 256; ++j) {
            auto tj = decode_type(static_cast<uint8_t>(j));
            int sj = base_to_sybyl_parent(tj.base_type);
            if (sj < 0 || static_cast<size_t>(sj) >= N_SYBYL) continue;

            accum[si * N_SYBYL + sj] += matrix.lookup(
                static_cast<uint8_t>(i), static_cast<uint8_t>(j));
            counts[si * N_SYBYL + sj]++;
        }
    }

    for (size_t idx = 0; idx < N_SYBYL * N_SYBYL; ++idx) {
        out_40x40[idx] = (counts[idx] > 0)
            ? accum[idx] / static_cast<float>(counts[idx])
            : 0.0f;
    }
}

// =============================================================================
// ShannonEnergyMatrix — Two-Stage Pose Scoring
// =============================================================================

ScoringResult ShannonEnergyMatrix::score_poses_two_stage(
    const uint8_t* pose_types_i,
    const uint8_t* pose_types_j,
    const float* distances,
    size_t n_poses,
    size_t contacts_per_pose,
    float cutoff_percentile
) const noexcept {
    if (n_poses == 0 || contacts_per_pose == 0 ||
        !pose_types_i || !pose_types_j || !distances) {
        return ScoringResult{0.0, 0, 0, 0.0};
    }

    // Guard against size_t overflow in total element count
    if (n_poses > SIZE_MAX / contacts_per_pose) {
        return ScoringResult{0.0, 0, 0, 0.0};
    }

    // Stage 1: Matrix pre-filter — fast O(1) lookup per contact
    std::vector<float> raw_scores(n_poses, 0.0f);

    // Use batch_lookup on soft_contact_ for SIMD acceleration
    for (size_t pose = 0; pose < n_poses; ++pose) {
        const size_t offset = pose * contacts_per_pose;
        float score = 0.0f;
        for (size_t c = 0; c < contacts_per_pose; ++c) {
            score += soft_contact_.lookup(
                pose_types_i[offset + c],
                pose_types_j[offset + c]);
        }
        raw_scores[pose] = score;
    }

    // Sort indices by raw score (lower energy = better)
    std::vector<size_t> sorted_indices(n_poses);
    std::iota(sorted_indices.begin(), sorted_indices.end(), 0);
    std::sort(sorted_indices.begin(), sorted_indices.end(),
        [&](size_t a, size_t b) { return raw_scores[a] < raw_scores[b]; });

    // Keep top percentile
    size_t n_keep = std::max(static_cast<size_t>(1),
        static_cast<size_t>(n_poses * cutoff_percentile));
    n_keep = std::min(n_keep, n_poses);

    // Stage 2: Analytic refinement on survivors
    // Full LJ + Coulomb + desolvation with distance-dependent kernels
    std::vector<double> refined_energies(n_keep);

    for (size_t si = 0; si < n_keep; ++si) {
        size_t pose = sorted_indices[si];
        const size_t offset = pose * contacts_per_pose;
        double e_total = 0.0;

        for (size_t c = 0; c < contacts_per_pose; ++c) {
            uint8_t ti = pose_types_i[offset + c];
            uint8_t tj = pose_types_j[offset + c];
            float r = distances[offset + c];

            auto info_i = decode_type(ti);
            auto info_j = decode_type(tj);

            double sigma_i = 1.4 + (info_i.base_type / 31.0) * 2.6;
            double sigma_j = 1.4 + (info_j.base_type / 31.0) * 2.6;
            double eps_i = 0.02 + (info_i.base_type / 31.0) * 0.28;
            double eps_j = 0.02 + (info_j.base_type / 31.0) * 0.28;
            double q_i = (info_i.charge_bin == 0) ? -0.8 :
                         (info_i.charge_bin == 1) ? -0.2 :
                         (info_i.charge_bin == 2) ?  0.2 : 0.8;
            double q_j = (info_j.charge_bin == 0) ? -0.8 :
                         (info_j.charge_bin == 1) ? -0.2 :
                         (info_j.charge_bin == 2) ?  0.2 : 0.8;

            double sigma_ij = (sigma_i + sigma_j) / 2.0;
            double eps_ij = std::sqrt(eps_i * eps_j);
            double r_ij = static_cast<double>(r);
            if (r_ij < 0.5) r_ij = 0.5;  // prevent singularity

            double hbond_bonus = (info_i.hbond != info_j.hbond) ? -0.5 : 0.0;

            // LJ 12-6
            double sr = sigma_ij / r_ij;
            double sr6 = sr * sr * sr * sr * sr * sr;
            double e_lj = eps_ij * (sr6 * sr6 - 2.0 * sr6);

            // Debye-Hückel
            constexpr double kappa = 0.3;
            constexpr double coulomb_const = 332.06;
            double e_elec = coulomb_const * q_i * q_j
                          * std::exp(-kappa * r_ij) / r_ij;

            // Desolvation
            constexpr double gamma = 0.005;
            double sa_i = 4.0 * std::numbers::pi * sigma_i * sigma_i;
            double sa_j = 4.0 * std::numbers::pi * sigma_j * sigma_j;
            double e_desolv = gamma * (sa_i + sa_j);

            // Distance-dependent Gaussian kernel
            double kernel = std::exp(-r_ij * r_ij / 18.0);  // σ=3.0 Å
            e_total += (e_lj + e_elec + e_desolv + hbond_bonus) * kernel;
        }

        refined_energies[si] = e_total;
    }

    // Stage 3: Boltzmann-weighted entropy
    constexpr double kT = 0.592;  // kcal/mol at 298 K
    double max_neg_e = *std::min_element(refined_energies.begin(),
                                         refined_energies.end());

    std::vector<double> boltzmann_weights(n_keep);
    double Z = 0.0;
    for (size_t i = 0; i < n_keep; ++i) {
        boltzmann_weights[i] = std::exp(-(refined_energies[i] - max_neg_e) / kT);
        Z += boltzmann_weights[i];
    }

    double H = 0.0;
    double dg_sum = 0.0;
    if (Z > 0.0) {
        for (size_t i = 0; i < n_keep; ++i) {
            double p = boltzmann_weights[i] / Z;
            if (p > 0.0) {
                H -= p * std::log2(p);
            }
            dg_sum += p * refined_energies[i];
        }
    }

    return ScoringResult{H, n_keep, n_poses, dg_sum};
}

}  // namespace shannon
