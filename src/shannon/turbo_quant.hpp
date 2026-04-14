// turbo_quant.hpp — TurboQuant integration for Shannon 2.0
//
// Ported from FlexAIDdS TurboQuant.h. Provides MSE-optimal scalar quantization
// for zero-overhead entropy monitoring on quantized token distributions.
//
// The "bounded entropy error < 0.01 bits" guarantee from arXiv:2504.19874 applies
// only to normalized probability distributions. For arbitrary logit vectors, the
// quantized entropy may differ from full-precision entropy by more than 1 bit
// depending on the spread and quantization resolution.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#pragma once

#include "shannon/config.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace shannon::quant {

// ─── Codebook for scalar quantization ────────────────────────────────────────

struct Codebook {
    int bits;                       // Quantization bits (default: 4)
    int levels;                     // 2^bits
    std::vector<double> centroids;  // levels centroids
    double scale;                   // Global scale factor
    double offset;                  // Offset before quantization
};

// ─── Quantized token distribution ────────────────────────────────────────────

struct QuantizedDistribution {
    std::vector<uint8_t> indices;   // Quantized indices (4-bit packed)
    Codebook codebook;
    std::size_t n;                  // Original distribution size
};

// ─── TurboQuant operations ───────────────────────────────────────────────────

// Build optimal codebook from a sample distribution using Lloyd-Max
Codebook build_codebook(const double* values, std::size_t n, int bits = kDefaultTurboQuantBits);

// Quantize a distribution using a pre-built codebook
QuantizedDistribution quantize(const double* values, std::size_t n, const Codebook& cb);

// Dequantize to recover approximate probabilities
std::vector<double> dequantize(const QuantizedDistribution& qd);

// Compute entropy directly on quantized indices (fast, bounded error)
double entropy_quantized(const QuantizedDistribution& qd);

// Full pipeline: quantize + compute entropy in one pass
double quantized_entropy(const double* logits, std::size_t n,
                         int bits = kDefaultTurboQuantBits);

}  // namespace shannon::quant
