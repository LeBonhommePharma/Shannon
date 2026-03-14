// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT

#include "contact/soft_contact_matrix.hpp"
#include "contact/atom_types.hpp"

#include <gtest/gtest.h>

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>
#include <vector>

using namespace shannon::contact;

// ─── Atom Type Encoding ─────────────────────────────────────────────────────

TEST(AtomTypes, EncodeDecodeRoundTrip) {
    for (uint8_t base = 0; base < 32; ++base) {
        for (uint8_t charge = 0; charge < 4; ++charge) {
            for (uint8_t hbond = 0; hbond < 2; ++hbond) {
                const uint8_t encoded = encode_atom_type(base, charge, hbond);
                EXPECT_EQ(decode_base_type(encoded), base);
                EXPECT_EQ(decode_charge_bin(encoded), charge);
                EXPECT_EQ(decode_hbond_flag(encoded), hbond);
            }
        }
    }
}

TEST(AtomTypes, AllValuesDistinct) {
    bool seen[256] = {};
    for (uint8_t base = 0; base < 32; ++base) {
        for (uint8_t charge = 0; charge < 4; ++charge) {
            for (uint8_t hbond = 0; hbond < 2; ++hbond) {
                const uint8_t encoded = encode_atom_type(base, charge, hbond);
                EXPECT_FALSE(seen[encoded])
                    << "Duplicate at base=" << (int)base
                    << " charge=" << (int)charge
                    << " hbond=" << (int)hbond;
                seen[encoded] = true;
            }
        }
    }
    // All 256 values should be covered
    for (int i = 0; i < 256; ++i) {
        EXPECT_TRUE(seen[i]) << "Missing value " << i;
    }
}

TEST(AtomTypes, EnumOverload) {
    const uint8_t t = encode_atom_type(BaseAtomType::C_ar, ChargeBin::WeakNeg, true);
    EXPECT_EQ(decode_base_type(t), 3);   // C_ar = 3
    EXPECT_EQ(decode_charge_bin(t), 1);  // WeakNeg = 1
    EXPECT_EQ(decode_hbond_flag(t), 1);
}

TEST(AtomTypes, ChargeBinning) {
    EXPECT_EQ(bin_partial_charge(-0.5f), ChargeBin::StrongNeg);
    EXPECT_EQ(bin_partial_charge(-0.1f), ChargeBin::WeakNeg);
    EXPECT_EQ(bin_partial_charge(0.1f),  ChargeBin::WeakPos);
    EXPECT_EQ(bin_partial_charge(0.5f),  ChargeBin::StrongPos);
    // Boundary cases
    EXPECT_EQ(bin_partial_charge(-0.25f), ChargeBin::WeakNeg);
    EXPECT_EQ(bin_partial_charge(0.0f),   ChargeBin::WeakPos);
    EXPECT_EQ(bin_partial_charge(0.25f),  ChargeBin::StrongPos);
}

TEST(AtomTypes, SybylParent) {
    // sybyl_parent strips charge and hbond, returns base type
    const uint8_t t = encode_atom_type(7, 3, 1);  // N_ar, StrongPos, hbond
    EXPECT_EQ(sybyl_parent(t), 7);
}

// ─── SoftContactMatrix Construction ─────────────────────────────────────────

TEST(SoftContactMatrix, ZeroInitialized) {
    SoftContactMatrix m;
    for (std::size_t i = 0; i < kMatrixSize; ++i) {
        EXPECT_FLOAT_EQ(m.data()[i], 0.0f);
    }
}

TEST(SoftContactMatrix, CacheAlignment) {
    SoftContactMatrix m;
    auto ptr = reinterpret_cast<std::uintptr_t>(m.data());
    EXPECT_EQ(ptr % 64, 0u) << "data_ not 64-byte aligned";
}

// ─── Lookup and Access ──────────────────────────────────────────────────────

TEST(SoftContactMatrix, LookupAndAt) {
    SoftContactMatrix m;
    m.at(10, 20) = 3.14f;
    m.at(200, 100) = -2.71f;

    EXPECT_FLOAT_EQ(m.lookup(10, 20), 3.14f);
    EXPECT_FLOAT_EQ(m.lookup(200, 100), -2.71f);
    EXPECT_FLOAT_EQ(m.lookup(0, 0), 0.0f);
}

// ─── Symmetry ───────────────────────────────────────────────────────────────

TEST(SoftContactMatrix, Symmetrize) {
    SoftContactMatrix m;
    m.at(5, 10) = 4.0f;
    m.at(10, 5) = 2.0f;

    EXPECT_FALSE(m.is_symmetric());

    m.symmetrize();

    EXPECT_FLOAT_EQ(m.lookup(5, 10), 3.0f);
    EXPECT_FLOAT_EQ(m.lookup(10, 5), 3.0f);
    EXPECT_TRUE(m.is_symmetric());
}

TEST(SoftContactMatrix, EmptyIsSymmetric) {
    SoftContactMatrix m;
    EXPECT_TRUE(m.is_symmetric());
}

// ─── Load / Save Round-Trip ─────────────────────────────────────────────────

TEST(SoftContactMatrix, SaveLoadRoundTrip) {
    SoftContactMatrix orig;
    // Fill with deterministic values
    std::mt19937 rng(42);
    std::uniform_real_distribution<float> dist(-10.0f, 10.0f);
    for (std::size_t i = 0; i < kMatrixSize; ++i) {
        orig.data()[i] = dist(rng);
    }

    const char* tmp_path = "/tmp/test_scm_roundtrip.bin";
    orig.save(tmp_path);

    SoftContactMatrix loaded;
    loaded.load(tmp_path);

    for (std::size_t i = 0; i < kMatrixSize; ++i) {
        EXPECT_FLOAT_EQ(loaded.data()[i], orig.data()[i])
            << "Mismatch at index " << i;
    }

    std::remove(tmp_path);
}

TEST(SoftContactMatrix, LoadRawBlob) {
    // Create a raw blob (no header)
    std::vector<float> raw(kMatrixSize, 0.0f);
    raw[0] = 1.0f;
    raw[kMatrixSize - 1] = -1.0f;

    const char* tmp_path = "/tmp/test_scm_raw.bin";
    FILE* fp = std::fopen(tmp_path, "wb");
    ASSERT_NE(fp, nullptr);
    std::fwrite(raw.data(), sizeof(float), kMatrixSize, fp);
    std::fclose(fp);

    SoftContactMatrix m;
    m.load(tmp_path);

    EXPECT_FLOAT_EQ(m.lookup(0, 0), 1.0f);
    EXPECT_FLOAT_EQ(m.lookup(255, 255), -1.0f);

    std::remove(tmp_path);
}

TEST(SoftContactMatrix, LoadInvalidSizeThrows) {
    const char* tmp_path = "/tmp/test_scm_bad.bin";
    FILE* fp = std::fopen(tmp_path, "wb");
    ASSERT_NE(fp, nullptr);
    float bad = 1.0f;
    std::fwrite(&bad, sizeof(float), 1, fp);
    std::fclose(fp);

    SoftContactMatrix m;
    EXPECT_THROW(m.load(tmp_path), std::runtime_error);

    std::remove(tmp_path);
}

TEST(SoftContactMatrix, LoadFromBuffer) {
    std::vector<float> buf(kMatrixSize, 0.0f);
    buf[256 * 3 + 7] = 42.0f;  // type_i=3, type_j=7

    SoftContactMatrix m;
    m.load_from_buffer(buf.data());

    EXPECT_FLOAT_EQ(m.lookup(3, 7), 42.0f);
}

// ─── Pose Activation ────────────────────────────────────────────────────────

TEST(SoftContactMatrix, PoseActivation) {
    SoftContactMatrix m;
    // Set up a simple matrix
    m.at(1, 2) = 5.0f;
    m.at(3, 4) = 3.0f;

    ContactPair contacts[] = {
        {1, 2, 1.0f},  // contributes 5.0 to types 1 and 2
        {3, 4, 2.0f},  // contributes 3.0 * 2.0 = 6.0 to types 3 and 4
    };

    float activation[256] = {};
    m.pose_activation(contacts, 2, activation);

    EXPECT_FLOAT_EQ(activation[1], 5.0f);
    EXPECT_FLOAT_EQ(activation[2], 5.0f);
    EXPECT_FLOAT_EQ(activation[3], 6.0f);
    EXPECT_FLOAT_EQ(activation[4], 6.0f);
    EXPECT_FLOAT_EQ(activation[0], 0.0f);  // untouched
}

// ─── Contact Scoring ────────────────────────────────────────────────────────

TEST(SoftContactMatrix, ScoreContacts) {
    SoftContactMatrix m;
    m.at(1, 2) = 5.0f;
    m.at(3, 4) = 3.0f;

    ContactPair contacts[] = {
        {1, 2, 1.0f},
        {3, 4, 2.0f},
    };

    float score = m.score_contacts(contacts, 2);
    EXPECT_FLOAT_EQ(score, 5.0f + 6.0f);  // 5*1 + 3*2
}

TEST(SoftContactMatrix, ScoreEmptyContacts) {
    SoftContactMatrix m;
    EXPECT_FLOAT_EQ(m.score_contacts(nullptr, 0), 0.0f);
}

// ─── Performance Sanity ─────────────────────────────────────────────────────

TEST(SoftContactMatrix, LookupPerformance) {
    SoftContactMatrix m;
    std::mt19937 rng(123);
    std::uniform_int_distribution<int> dist(0, 255);

    // Fill with random values
    for (std::size_t i = 0; i < kMatrixSize; ++i) {
        m.data()[i] = static_cast<float>(i) * 0.001f;
    }

    // 1M random lookups — just ensure no crash and accumulate to prevent
    // the compiler from optimizing away the lookups.
    float accum = 0.0f;
    for (int i = 0; i < 1'000'000; ++i) {
        const auto ti = static_cast<uint8_t>(dist(rng));
        const auto tj = static_cast<uint8_t>(dist(rng));
        accum += m.lookup(ti, tj);
    }

    // Accum should be non-zero (but the exact value doesn't matter)
    EXPECT_NE(accum, 0.0f);
}
