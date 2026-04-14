// turbo_quant.cpp — TurboQuant implementation for Shannon 2.0
//
// MSE-optimal scalar quantization using Lloyd-Max algorithm.
// Provides bounded-entropy-error monitoring of quantized token distributions.
//
// Apache-2.0 © 2026 Le Bonhomme Pharma
#include "shannon/turbo_quant.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace shannon::quant {

// ─── Codebook construction (Lloyd-Max) ───────────────────────────────────────

Codebook build_codebook(const double* values, std::size_t n, int bits) {
    Codebook cb;
    if (bits < 1) bits = 1;
    if (bits > 8) bits = 8;
    cb.bits = bits;
    cb.levels = 1 << bits;
    cb.centroids.resize(cb.levels);

    if (n == 0) return cb;

    // Find min/max
    double vmin = values[0];
    double vmax = values[0];
    for (std::size_t i = 1; i < n; ++i) {
        if (!std::isfinite(values[i])) continue;
        if (values[i] < vmin) vmin = values[i];
        if (values[i] > vmax) vmax = values[i];
    }

    cb.offset = vmin;
    cb.scale = (vmax > vmin) ? (vmax - vmin) : 1.0;

    // Initialize centroids uniformly
    for (int i = 0; i < cb.levels; ++i) {
        cb.centroids[i] = vmin + (static_cast<double>(i) + 0.5) * cb.scale / cb.levels;
    }

    // Lloyd-Max iterations (5 iterations sufficient for convergence)
    for (int iter = 0; iter < 5; ++iter) {
        // Assign values to nearest centroid and compute new centroids
        std::vector<double> sums(cb.levels, 0.0);
        std::vector<int> counts(cb.levels, 0);

        for (std::size_t i = 0; i < n; ++i) {
            int best = 0;
            double best_dist = std::abs(values[i] - cb.centroids[0]);
            for (int j = 1; j < cb.levels; ++j) {
                double d = std::abs(values[i] - cb.centroids[j]);
                if (d < best_dist) {
                    best_dist = d;
                    best = j;
                }
            }
            sums[best] += values[i];
            counts[best]++;
        }

        // Update centroids
        for (int j = 0; j < cb.levels; ++j) {
            if (counts[j] > 0) {
                cb.centroids[j] = sums[j] / counts[j];
            }
        }
    }

    return cb;
}

// ─── Quantize ────────────────────────────────────────────────────────────────

QuantizedDistribution quantize(const double* values, std::size_t n, const Codebook& cb) {
    QuantizedDistribution qd;
    qd.codebook = cb;
    qd.n = n;
    qd.indices.resize(n);

    for (std::size_t i = 0; i < n; ++i) {
        int best = 0;
        double best_dist = std::abs(values[i] - cb.centroids[0]);
        for (int j = 1; j < cb.levels; ++j) {
            double d = std::abs(values[i] - cb.centroids[j]);
            if (d < best_dist) {
                best_dist = d;
                best = j;
            }
        }
        qd.indices[i] = static_cast<uint8_t>(best);
    }

    return qd;
}

// ─── Dequantize ──────────────────────────────────────────────────────────────

std::vector<double> dequantize(const QuantizedDistribution& qd) {
    std::vector<double> result(qd.n);
    for (std::size_t i = 0; i < qd.n; ++i) {
        result[i] = qd.codebook.centroids[qd.indices[i]];
    }
    return result;
}

// ─── Entropy on quantized indices ────────────────────────────────────────────
//
// Fast histogram-based entropy: count occurrences of each index,
// compute H = -Σ (count_k / N) * log2(count_k / N)

double entropy_quantized(const QuantizedDistribution& qd) {
    if (qd.n == 0) return 0.0;

    std::vector<int> counts(qd.codebook.levels, 0);
    for (std::size_t i = 0; i < qd.n; ++i) {
        counts[qd.indices[i]]++;
    }

    double h = 0.0;
    const double inv_n = 1.0 / static_cast<double>(qd.n);

    for (int k = 0; k < qd.codebook.levels; ++k) {
        if (counts[k] > 0) {
            double p = static_cast<double>(counts[k]) * inv_n;
            h -= p * std::log2(p);
        }
    }

    return std::max(0.0, h);
}

// ─── Full pipeline ───────────────────────────────────────────────────────────

double quantized_entropy(const double* logits, std::size_t n, int bits) {
    if (n <= 1) return 0.0;

    auto cb = build_codebook(logits, n, bits);
    auto qd = quantize(logits, n, cb);
    return entropy_quantized(qd);
}

}  // namespace shannon::quant
