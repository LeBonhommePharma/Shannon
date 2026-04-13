// config.hpp — Shannon compile-time constants and configuration
//
// Pure C++20 entropy collapse detection — Le Bonhomme Pharma / NRGlab
// Ported from FlexAIDdS configurational entropy engine
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include <cstddef>
#include <cstdint>

namespace shannon {

// ─── Mathematical constants ──────────────────────────────────────────────────

inline constexpr double kLn2     = 0.693147180559945309417;    // ln(2)
inline constexpr double kLog2E   = 1.44269504088896340736;     // log₂(e) = 1/ln(2)
inline constexpr double kEpsilon = 1e-300;                      // numerical floor

// ─── Default detection parameters ────────────────────────────────────────────

inline constexpr double      kDefaultCollapseThreshold = -3.2;  // bits
inline constexpr std::size_t kDefaultWindowSize        = 8;     // sliding window
inline constexpr int         kDefaultTurboQuantBits     = 4;    // 4-bit quantization
inline constexpr int         kDefaultSustainedCount     = 3;    // consecutive collapses for escalation
inline constexpr double      kDefaultCooldownSeconds    = 5.0;  // min time between escalated actions

// ─── Version ─────────────────────────────────────────────────────────────────

inline constexpr int kVersionMajor = 2;
inline constexpr int kVersionMinor = 0;
inline constexpr int kVersionPatch = 0;

}  // namespace shannon
