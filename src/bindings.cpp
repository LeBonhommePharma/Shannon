// =============================================================================
// Shannon — pybind11 Bindings
//
// Zero-copy numpy array acceptance. GIL released during computation.
// Follows FlexAIDdS _core module pattern.
//
// Exposes: entropy functions, EntropyResult, CollapseEvent,
//          SlidingWindowEntropy, ShannonEnergyMatrix, SoftContactMatrix,
//          FastOPTICS, TypeInfo, SuperCluster, HardwareInfo.
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
#include "fast_optics.h"

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
        .def("window",
            [](const shannon::SlidingWindowEntropy& self) {
                const auto& w = self.window();
                return std::vector<double>(w.begin(), w.end());
            })
        .def("reset", &shannon::SlidingWindowEntropy::reset)
        .def("set_on_collapse",
            [](shannon::SlidingWindowEntropy& self, py::function callback) {
                self.set_on_collapse([callback](const shannon::CollapseEvent& event) {
                    py::gil_scoped_acquire acquire;
                    callback(event);
                });
            },
            py::arg("callback"));

    // ── TypeInfo (8-bit type encoding) ─────────────────────────────────────

    py::class_<shannon::TypeInfo>(m, "TypeInfo")
        .def_readonly("type_index", &shannon::TypeInfo::type_index)
        .def_readonly("base_type", &shannon::TypeInfo::base_type)
        .def_readonly("charge_bin", &shannon::TypeInfo::charge_bin)
        .def_readonly("hbond", &shannon::TypeInfo::hbond)
        .def("__repr__", [](const shannon::TypeInfo& t) {
            return "<TypeInfo idx=" + std::to_string(t.type_index) +
                   " base=" + std::to_string(t.base_type) +
                   " charge=" + std::to_string(t.charge_bin) +
                   " hbond=" + std::to_string(t.hbond) + ">";
        });

    m.def("decode_type", &shannon::decode_type, py::arg("type_index"),
          "Decode 8-bit type index into (base_type, charge_bin, hbond)");
    m.def("encode_type", &shannon::encode_type,
          py::arg("base"), py::arg("charge"), py::arg("hbond"),
          "Encode (base_type, charge_bin, hbond) into 8-bit type index");

    // ── SoftContactMatrix ──────────────────────────────────────────────────

    py::class_<shannon::SoftContactMatrix>(m, "SoftContactMatrix")
        .def(py::init<>())
        .def("load", &shannon::SoftContactMatrix::load, py::arg("path"),
             "Load from binary blob (SC01 format)")
        .def("lookup", &shannon::SoftContactMatrix::lookup,
             py::arg("type_i"), py::arg("type_j"),
             "O(1) energy lookup")
        .def("is_loaded", &shannon::SoftContactMatrix::is_loaded)
        .def("batch_lookup",
            [](const shannon::SoftContactMatrix& self,
               py::array_t<uint8_t> types_i, py::array_t<uint8_t> types_j) {
                auto bi = types_i.request();
                auto bj = types_j.request();
                if (bi.ndim != 1) throw std::runtime_error("types_i must be 1D");
                if (bj.ndim != 1) throw std::runtime_error("types_j must be 1D");
                if (bi.size != bj.size) throw std::runtime_error("types_i and types_j must have same length");
                size_t n = bi.size;
                auto result = py::array_t<float>(n);
                auto br = result.request();
                {
                    py::gil_scoped_release release;
                    self.batch_lookup(
                        static_cast<uint8_t*>(bi.ptr),
                        static_cast<uint8_t*>(bj.ptr),
                        static_cast<float*>(br.ptr), n);
                }
                return result;
            },
            py::arg("types_i"), py::arg("types_j"),
            "Batch lookup: scores[k] = matrix[types_i[k], types_j[k]] (SIMD accelerated)")
        .def("row_dot",
            [](const shannon::SoftContactMatrix& self,
               uint8_t type_i, py::array_t<float> weights) {
                auto bw = weights.request();
                if (bw.ndim != 1) throw std::runtime_error("weights must be 1D");
                if (bw.size != 256) throw std::runtime_error("weights must be length 256");
                py::gil_scoped_release release;
                return self.row_dot(type_i, static_cast<float*>(bw.ptr));
            },
            py::arg("type_i"), py::arg("weights"),
            "Dot product of matrix row with 256-d weight vector (FMA accelerated)")
        .def_readonly_static("DIM", &shannon::SoftContactMatrix::DIM)
        .def_readonly_static("BYTE_SIZE", &shannon::SoftContactMatrix::BYTE_SIZE);

    // ── SuperCluster ───────────────────────────────────────────────────────

    py::class_<shannon::SuperCluster>(m, "SuperCluster")
        .def(py::init<>())
        .def_readwrite("member_types", &shannon::SuperCluster::member_types)
        .def_readwrite("centroid", &shannon::SuperCluster::centroid)
        .def_readwrite("radius", &shannon::SuperCluster::radius)
        .def_readwrite("cluster_id", &shannon::SuperCluster::cluster_id);

    // ── ScoringResult ──────────────────────────────────────────────────────

    py::class_<shannon::ScoringResult>(m, "ScoringResult")
        .def_readonly("entropy", &shannon::ScoringResult::entropy)
        .def_readonly("poses_evaluated", &shannon::ScoringResult::poses_evaluated)
        .def_readonly("poses_total", &shannon::ScoringResult::poses_total)
        .def_readonly("delta_g_proxy", &shannon::ScoringResult::delta_g_proxy)
        .def("__repr__", [](const shannon::ScoringResult& r) {
            return "<ScoringResult H=" + std::to_string(r.entropy) +
                   " evaluated=" + std::to_string(r.poses_evaluated) +
                   "/" + std::to_string(r.poses_total) +
                   " dG=" + std::to_string(r.delta_g_proxy) + ">";
        });

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
        .def("get_row_vector", &shannon::ShannonEnergyMatrix::get_row_vector,
             py::arg("type_i"),
             "Get 256-d row vector for clustering")
        .def("nonzero_count", &shannon::ShannonEnergyMatrix::nonzero_count)
        .def("source", &shannon::ShannonEnergyMatrix::source,
             "Source of matrix data: 'soft_contact' or 'closed_form'")
        .def("score_poses_two_stage",
            [](const shannon::ShannonEnergyMatrix& self,
               py::array_t<uint8_t> types_i, py::array_t<uint8_t> types_j,
               py::array_t<float> distances,
               size_t n_poses, size_t contacts_per_pose,
               float cutoff_percentile) {
                auto bi = types_i.request();
                auto bj = types_j.request();
                auto bd = distances.request();
                if (bi.ndim != 1) throw std::runtime_error("types_i must be 1D");
                if (bj.ndim != 1) throw std::runtime_error("types_j must be 1D");
                if (bd.ndim != 1) throw std::runtime_error("distances must be 1D");
                size_t total = n_poses * contacts_per_pose;
                if (static_cast<size_t>(bi.size) < total)
                    throw std::runtime_error("types_i too short: need " + std::to_string(total) +
                                             " elements, got " + std::to_string(bi.size));
                if (static_cast<size_t>(bj.size) < total)
                    throw std::runtime_error("types_j too short: need " + std::to_string(total) +
                                             " elements, got " + std::to_string(bj.size));
                if (static_cast<size_t>(bd.size) < total)
                    throw std::runtime_error("distances too short: need " + std::to_string(total) +
                                             " elements, got " + std::to_string(bd.size));
                py::gil_scoped_release release;
                return self.score_poses_two_stage(
                    static_cast<uint8_t*>(bi.ptr),
                    static_cast<uint8_t*>(bj.ptr),
                    static_cast<float*>(bd.ptr),
                    n_poses, contacts_per_pose, cutoff_percentile);
            },
            py::arg("types_i"), py::arg("types_j"), py::arg("distances"),
            py::arg("n_poses"), py::arg("contacts_per_pose"),
            py::arg("cutoff_percentile") = 0.10f,
            "Two-stage scoring: matrix pre-filter + analytic refinement")
        .def_readonly_static("DIM", &shannon::ShannonEnergyMatrix::DIM)
        .def_readonly_static("TOTAL_PARAMS", &shannon::ShannonEnergyMatrix::TOTAL_PARAMS);

    // ── FastOPTICS ─────────────────────────────────────────────────────────

    py::class_<shannon::FastOPTICS::Params>(m, "FastOPTICSParams")
        .def(py::init<>())
        .def_readwrite("min_pts", &shannon::FastOPTICS::Params::min_pts)
        .def_readwrite("n_projections", &shannon::FastOPTICS::Params::n_projections)
        .def_readwrite("xi", &shannon::FastOPTICS::Params::xi)
        .def_readwrite("seed", &shannon::FastOPTICS::Params::seed);

    py::class_<shannon::OPTICSPoint>(m, "OPTICSPoint")
        .def_readonly("index", &shannon::OPTICSPoint::index)
        .def_readonly("reachability_dist", &shannon::OPTICSPoint::reachability_dist)
        .def_readonly("core_dist", &shannon::OPTICSPoint::core_dist)
        .def_readonly("cluster_id", &shannon::OPTICSPoint::cluster_id);

    py::class_<shannon::ClusterResult>(m, "ClusterResult")
        .def_readonly("ordering", &shannon::ClusterResult::ordering)
        .def_readonly("clusters", &shannon::ClusterResult::clusters)
        .def_readonly("centroids", &shannon::ClusterResult::centroids)
        .def_readonly("n_clusters", &shannon::ClusterResult::n_clusters)
        .def_readonly("n_noise", &shannon::ClusterResult::n_noise);

    py::class_<shannon::FastOPTICS>(m, "FastOPTICS")
        .def(py::init<shannon::FastOPTICS::Params>(),
             py::arg("params") = shannon::FastOPTICS::Params{})
        .def("cluster",
            [](const shannon::FastOPTICS& self, py::array_t<float> data) {
                auto buf = data.request();
                if (buf.ndim != 2) throw std::runtime_error("Expected 2D array");
                size_t n = buf.shape[0];
                size_t d = buf.shape[1];
                py::gil_scoped_release release;
                return self.cluster(static_cast<float*>(buf.ptr), n, d);
            },
            py::arg("data"),
            "Run FastOPTICS clustering on (n, d) float32 array")
        .def("params", &shannon::FastOPTICS::params);

    // ── Hardware info ──────────────────────────────────────────────────────

    py::class_<shannon::HardwareInfo>(m, "HardwareInfo")
        .def_readonly("has_avx512", &shannon::HardwareInfo::has_avx512)
        .def_readonly("has_avx2", &shannon::HardwareInfo::has_avx2)
        .def_readonly("has_neon", &shannon::HardwareInfo::has_neon)
        .def_readonly("has_openmp", &shannon::HardwareInfo::has_openmp)
        .def_readonly("has_cuda", &shannon::HardwareInfo::has_cuda)
        .def_readonly("has_metal", &shannon::HardwareInfo::has_metal)
        .def_readonly("active_backend", &shannon::HardwareInfo::active_backend)
        .def("__repr__", [](const shannon::HardwareInfo& h) {
            return "<HardwareInfo backend='" + h.active_backend + "'>";
        });

    m.def("get_hardware_info", &shannon::get_hardware_info,
          "Query available hardware acceleration backends");

    // ── SYBYL bridge ──────────────────────────────────────────────────────

    m.def("sybyl_to_base",
        [](const std::string& sybyl_type) {
            return shannon::sybyl_to_base(sybyl_type.c_str());
        },
        py::arg("sybyl_type"),
        "Map SYBYL atom type string to base type (0-31). Returns -1 for unknown.");

    m.def("base_to_sybyl_parent", &shannon::base_to_sybyl_parent,
          py::arg("base_type"),
          "Map base type (0-31) back to SYBYL parent index (0-39)");

    m.def("project_to_40x40",
        [](const shannon::SoftContactMatrix& matrix) {
            auto result = py::array_t<float>({32, 32});
            auto buf = result.request();
            py::gil_scoped_release release;
            shannon::project_to_40x40(matrix, static_cast<float*>(buf.ptr));
            return result;
        },
        py::arg("matrix"),
        "Project 256x256 matrix to 32x32 SYBYL-equivalent (block-mean)");

    // ── Module-level constants ─────────────────────────────────────────────
    m.attr("__version__") = "0.2.0";
}
