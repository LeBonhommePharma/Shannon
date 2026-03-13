// =============================================================================
// Shannon — pybind11 Bindings
//
// Zero-copy numpy array acceptance. GIL released during computation.
// Follows FlexAIDdS _core module pattern.
//
// Copyright 2024-2026 Louis-Philippe Morency
// Licensed under the Apache License, Version 2.0
// =============================================================================

#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>
#include <pybind11/functional.h>

#include "shannon.h"
#include "energy_matrix.h"

namespace py = pybind11;

// Helper: accept float32 or float64 numpy arrays, return double*
static std::vector<double> to_double_vec(py::array arr) {
    if (arr.dtype().is(py::dtype::of<double>())) {
        auto buf = arr.cast<py::array_t<double>>().request();
        return std::vector<double>(
            static_cast<double*>(buf.ptr),
            static_cast<double*>(buf.ptr) + buf.size
        );
    }
    // float32 -> double conversion
    auto f32 = arr.cast<py::array_t<float>>().request();
    std::vector<double> result(f32.size);
    auto* src = static_cast<float*>(f32.ptr);
    for (ssize_t i = 0; i < f32.size; ++i) {
        result[i] = static_cast<double>(src[i]);
    }
    return result;
}

PYBIND11_MODULE(_core, m) {
    m.doc() = "Shannon entropy collapse detection — C++ accelerated core";

    // ── Core entropy functions ─────────────────────────────────────────────

    m.def("shannon_entropy",
        [](py::array probs) {
            auto vec = to_double_vec(probs);
            py::gil_scoped_release release;
            return shannon::shannon_entropy(vec.data(), vec.size());
        },
        py::arg("probs"),
        "Compute Shannon entropy H = -sum(p_i * log2(p_i)) in bits"
    );

    m.def("shannon_entropy_from_logits",
        [](py::array logits) {
            auto vec = to_double_vec(logits);
            py::gil_scoped_release release;
            return shannon::shannon_entropy_from_logits(vec.data(), vec.size());
        },
        py::arg("logits"),
        "Compute Shannon entropy from raw logits via fused log-sum-exp (numerically stable)"
    );

    // ── EntropyResult ──────────────────────────────────────────────────────

    py::class_<shannon::EntropyResult>(m, "EntropyResult")
        .def_readonly("H", &shannon::EntropyResult::H,
                       "Shannon entropy in bits")
        .def_readonly("H_normalized", &shannon::EntropyResult::H_normalized,
                       "Normalized entropy in [0, 1]")
        .def_readonly("collapsed", &shannon::EntropyResult::collapsed,
                       "Whether entropy indicates collapse")
        .def("__repr__", [](const shannon::EntropyResult& r) {
            return "<EntropyResult H=" + std::to_string(r.H) +
                   " H_norm=" + std::to_string(r.H_normalized) +
                   " collapsed=" + (r.collapsed ? "True" : "False") + ">";
        });

    m.def("compute_entropy",
        [](py::array probs, double threshold) {
            auto vec = to_double_vec(probs);
            py::gil_scoped_release release;
            return shannon::compute_entropy(vec.data(), vec.size(), threshold);
        },
        py::arg("probs"), py::arg("collapse_threshold") = 0.1
    );

    m.def("compute_entropy_from_logits",
        [](py::array logits, double threshold) {
            auto vec = to_double_vec(logits);
            py::gil_scoped_release release;
            return shannon::compute_entropy_from_logits(vec.data(), vec.size(), threshold);
        },
        py::arg("logits"), py::arg("collapse_threshold") = 0.1
    );

    // ── CollapseEvent ──────────────────────────────────────────────────────

    py::class_<shannon::CollapseEvent>(m, "CollapseEvent")
        .def_readonly("token_index", &shannon::CollapseEvent::token_index)
        .def_readonly("entropy", &shannon::CollapseEvent::entropy)
        .def_readonly("delta_h", &shannon::CollapseEvent::delta_h)
        .def_readonly("collapse_score", &shannon::CollapseEvent::collapse_score);

    // ── SlidingWindowEntropy ───────────────────────────────────────────────

    py::class_<shannon::SlidingWindowEntropy>(m, "SlidingWindowEntropy")
        .def(py::init<size_t, double>(),
             py::arg("window_size") = 8,
             py::arg("collapse_threshold") = -3.2)
        .def("push", &shannon::SlidingWindowEntropy::push,
             py::arg("entropy_value"))
        .def("push_logits",
            [](shannon::SlidingWindowEntropy& self, py::array logits) {
                auto vec = to_double_vec(logits);
                py::gil_scoped_release release;
                self.push_logits(vec.data(), vec.size());
            },
            py::arg("logits"))
        .def("current_entropy", &shannon::SlidingWindowEntropy::current_entropy)
        .def("mean_entropy", &shannon::SlidingWindowEntropy::mean_entropy)
        .def("delta_h", &shannon::SlidingWindowEntropy::delta_h)
        .def("is_collapsed", &shannon::SlidingWindowEntropy::is_collapsed)
        .def("collapse_score", &shannon::SlidingWindowEntropy::collapse_score)
        .def("token_count", &shannon::SlidingWindowEntropy::token_count)
        .def("reset", &shannon::SlidingWindowEntropy::reset)
        .def("set_on_collapse",
            [](shannon::SlidingWindowEntropy& self, py::function callback) {
                self.set_on_collapse([callback](const shannon::CollapseEvent& event) {
                    py::gil_scoped_acquire acquire;
                    callback(event);
                });
            },
            py::arg("callback"));

    // ── ShannonEnergyMatrix (256x256 white-box referee) ────────────────────

    py::class_<shannon::ShannonEnergyMatrix>(m, "ShannonEnergyMatrix")
        .def_static("instance", &shannon::ShannonEnergyMatrix::instance,
                     py::return_value_policy::reference,
                     "Get singleton instance of the 256x256 energy matrix")
        .def("energy", &shannon::ShannonEnergyMatrix::energy,
             py::arg("i"), py::arg("j"),
             "O(1) energy lookup — symmetric: E[i][j] == E[j][i]")
        .def("interaction_score", &shannon::ShannonEnergyMatrix::interaction_score,
             py::arg("token_a"), py::arg("token_b"))
        .def("nonzero_count", &shannon::ShannonEnergyMatrix::nonzero_count)
        .def_readonly_static("DIM", &shannon::ShannonEnergyMatrix::DIM)
        .def_readonly_static("TOTAL_PARAMS", &shannon::ShannonEnergyMatrix::TOTAL_PARAMS);

    // ── Hardware info ──────────────────────────────────────────────────────

    py::class_<shannon::HardwareInfo>(m, "HardwareInfo")
        .def_readonly("has_avx512", &shannon::HardwareInfo::has_avx512)
        .def_readonly("has_avx2", &shannon::HardwareInfo::has_avx2)
        .def_readonly("has_openmp", &shannon::HardwareInfo::has_openmp)
        .def_readonly("has_cuda", &shannon::HardwareInfo::has_cuda)
        .def_readonly("has_metal", &shannon::HardwareInfo::has_metal)
        .def_readonly("active_backend", &shannon::HardwareInfo::active_backend)
        .def("__repr__", [](const shannon::HardwareInfo& h) {
            return "<HardwareInfo backend='" + h.active_backend + "'>";
        });

    m.def("get_hardware_info", &shannon::get_hardware_info,
          "Query available hardware acceleration backends");

    // ── Module-level constants ─────────────────────────────────────────────
    m.attr("__version__") = "0.1.0";
}
