// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// 8-bit atom type encoding for the 256×256 soft contact matrix.
// Encodes element+hybridization (5 bits), partial charge bin (2 bits),
// and H-bond donor/acceptor flag (1 bit) into a single uint8_t.

#pragma once

#include <cstdint>
#include <array>

namespace shannon::contact {

// ─── Base Atom Types (5 bits = 32 values) ───────────────────────────────────
// Modeled after FlexAID SYBYL types, expanded for force-field resolution.

enum class BaseAtomType : std::uint8_t {
    C_sp3    =  0,   // sp3 carbon
    C_sp2    =  1,   // sp2 carbon
    C_sp     =  2,   // sp  carbon
    C_ar     =  3,   // aromatic carbon
    N_sp3    =  4,   // sp3 nitrogen
    N_sp2    =  5,   // sp2 nitrogen
    N_sp     =  6,   // sp  nitrogen
    N_ar     =  7,   // aromatic nitrogen
    N_am     =  8,   // amide nitrogen
    O_sp3    =  9,   // sp3 oxygen
    O_sp2    = 10,   // sp2 oxygen (carbonyl)
    O_ar     = 11,   // aromatic oxygen (furan)
    S_sp3    = 12,   // sp3 sulfur
    S_sp2    = 13,   // sp2 sulfur
    P_sp3    = 14,   // sp3 phosphorus
    F_       = 15,   // fluorine
    Cl_      = 16,   // chlorine
    Br_      = 17,   // bromine
    I_       = 18,   // iodine
    H_       = 19,   // non-polar hydrogen
    H_polar  = 20,   // polar hydrogen (bonded to N, O, S)
    Fe_      = 21,   // iron
    Zn_      = 22,   // zinc
    Mg_      = 23,   // magnesium
    Ca_      = 24,   // calcium
    Mn_      = 25,   // manganese
    Cu_      = 26,   // copper
    Co_      = 27,   // cobalt
    Se_      = 28,   // selenium
    Si_      = 29,   // silicon
    Reserved_30 = 30,
    Reserved_31 = 31,
};

inline constexpr std::uint8_t kNumBaseTypes   = 32;
inline constexpr std::uint8_t kNumChargeBins  = 4;
inline constexpr std::uint8_t kNumHBondStates = 2;
inline constexpr const char* kAtomTypeSchemaId =
    "shannon.contact.atom256.v1.base32.charge4.hbond1";
inline constexpr const char* kFlexAIDdSAtomTypeSchemaId =
    "flexaidds.atom256.v1.base64.charge2.hbond1";
inline constexpr std::uint32_t kAtomTypeSchemaVersion = 1;


// ─── Charge Bins ────────────────────────────────────────────────────────────
// Partial charge discretized into 4 bins.

enum class ChargeBin : std::uint8_t {
    StrongNeg = 0,   // q < -0.25
    WeakNeg   = 1,   // -0.25 <= q < 0.0
    WeakPos   = 2,   //  0.0  <= q < 0.25
    StrongPos = 3,   //  q >= 0.25
};

/// Bin a partial charge into one of 4 discrete levels.
inline constexpr ChargeBin bin_partial_charge(float q) noexcept {
    if (q < -0.25f) return ChargeBin::StrongNeg;
    if (q <  0.00f) return ChargeBin::WeakNeg;
    if (q <  0.25f) return ChargeBin::WeakPos;
    return ChargeBin::StrongPos;
}

// ─── 8-Bit Encoding / Decoding ──────────────────────────────────────────────
//
//   Bit layout:  [7: hbond] [6-5: charge_bin] [4-0: base_type]
//   Total:       2 × 4 × 32 = 256 unique types

/// Encode atom type fields into a single uint8_t index.
inline constexpr std::uint8_t encode_atom_type(
    std::uint8_t base_type,    // 0–31
    std::uint8_t charge_bin,   // 0–3
    std::uint8_t hbond_flag    // 0–1
) noexcept {
    return static_cast<std::uint8_t>(
        (hbond_flag << 7) | ((charge_bin & 0x03) << 5) | (base_type & 0x1F)
    );
}

/// Overload accepting enum types.
inline constexpr std::uint8_t encode_atom_type(
    BaseAtomType base,
    ChargeBin    charge,
    bool         hbond
) noexcept {
    return encode_atom_type(
        static_cast<std::uint8_t>(base),
        static_cast<std::uint8_t>(charge),
        static_cast<std::uint8_t>(hbond)
    );
}

/// Extract the base atom type (bits 0–4).
inline constexpr std::uint8_t decode_base_type(std::uint8_t atom_type) noexcept {
    return atom_type & 0x1F;
}

/// Extract the charge bin (bits 5–6).
inline constexpr std::uint8_t decode_charge_bin(std::uint8_t atom_type) noexcept {
    return (atom_type >> 5) & 0x03;
}

/// Extract the H-bond flag (bit 7).
inline constexpr std::uint8_t decode_hbond_flag(std::uint8_t atom_type) noexcept {
    return (atom_type >> 7) & 0x01;
}

// ─── SYBYL Bridge ───────────────────────────────────────────────────────────
// Bidirectional mapping between FlexAID's SYBYL world and the 256-type scheme.

/// FlexAID SYBYL mol2 type codes (subset of ~40 types used in the 40×40 CF).
enum class SybylType : std::uint8_t {
    C_3  =  0,   // sp3 carbon
    C_2  =  1,   // sp2 carbon
    C_1  =  2,   // sp  carbon
    C_ar =  3,   // aromatic carbon
    N_3  =  4,   // sp3 nitrogen
    N_2  =  5,   // sp2 nitrogen
    N_1  =  6,   // sp  nitrogen
    N_ar =  7,   // aromatic nitrogen
    N_am =  8,   // amide nitrogen
    O_3  =  9,   // sp3 oxygen
    O_2  = 10,   // sp2 oxygen
    O_ar = 11,   // aromatic oxygen
    S_3  = 12,   // sp3 sulfur
    S_2  = 13,   // sp2 sulfur
    P_3  = 14,   // sp3 phosphorus
    F    = 15,
    Cl   = 16,
    Br   = 17,
    I    = 18,
    H    = 19,
    H_pol = 20,
    // Metals
    Fe   = 21,
    Zn   = 22,
    Mg   = 23,
    Ca   = 24,
    Mn   = 25,
    Cu   = 26,
    Co   = 27,
    Se   = 28,
    Si   = 29,
    Unknown = 31,
};

inline constexpr std::uint8_t kNumSybylTypes = 32;

/// Convert SYBYL type to base atom type. Direct 1:1 mapping by design.
inline constexpr BaseAtomType sybyl_to_base(SybylType sybyl) noexcept {
    return static_cast<BaseAtomType>(static_cast<std::uint8_t>(sybyl));
}

/// Convert base atom type back to SYBYL parent for 256→40 projection.
inline constexpr SybylType base_to_sybyl_parent(BaseAtomType base) noexcept {
    return static_cast<SybylType>(static_cast<std::uint8_t>(base));
}

/// Return the SYBYL parent index (0–31 = base type) for a 256-type.
/// Strips charge bin and H-bond flag, returning the coarse SYBYL class.
inline constexpr std::uint8_t sybyl_parent(std::uint8_t atom_type) noexcept {
    return decode_base_type(atom_type);
}

/// Convert a SYBYL type + charge + hbond into a full 256-type.
inline constexpr std::uint8_t sybyl_to_256(
    SybylType sybyl,
    ChargeBin charge,
    bool      hbond
) noexcept {
    return encode_atom_type(sybyl_to_base(sybyl), charge, hbond);
}

// ─── Context-Aware Refinements ──────────────────────────────────────────────
// NATURaL-critical refinements for indole/tryptamine π-systems and
// heteroatom-adjacent aromatics. These distinguish subtypes that SYBYL
// conflates but that are pharmacologically distinct.

/// Context flags for aromatic carbons.
/// C_ar bonded to a heteroatom (N, O, S) has different dispersion behavior
/// than C_ar in a pure hydrocarbon ring (indole vs. benzene).
inline constexpr bool is_heteroatom_adjacent_aromatic(
    std::uint8_t base_type,
    bool has_hetero_neighbor
) noexcept {
    // C_ar (3) with heteroatom neighbor gets charge-shifted
    // This is encoded via the charge bin rather than a separate base type,
    // so the caller should adjust the charge bin when has_hetero_neighbor
    // is true and the atom's own charge is near zero.
    return base_type == static_cast<std::uint8_t>(BaseAtomType::C_ar)
        && has_hetero_neighbor;
}

/// Detect π-bridging atoms in fused ring systems (indole, purine, etc.)
/// These are atoms shared between two aromatic rings.
inline constexpr bool is_pi_bridging(
    std::uint8_t base_type,
    std::uint8_t ring_count
) noexcept {
    // Aromatic C or N in 2+ rings = bridging atom
    return (base_type == static_cast<std::uint8_t>(BaseAtomType::C_ar) ||
            base_type == static_cast<std::uint8_t>(BaseAtomType::N_ar))
        && ring_count >= 2;
}

}  // namespace shannon::contact
