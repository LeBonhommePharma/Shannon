// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// pybind11 bindings for Shannon entropy collapse detection.

#include <pybind11/pybind11.h>
#include <pybind11/stl.h>
#include <pybind11/functional.h>
#include <pybind11/numpy.h>

#include "shannon.hpp"

namespace py = pybind11;

PYBIND11_MODULE(_shannon_cpp, m) {
    m.doc() = "Shannon Entropy Collapse Detection — C++ accelerated core";

    // ── Free functions ──────────────────────────────────────────────────────

    m.def("shannon_configurational_entropy",
        [](py::array_t<double, py::array::c_style | py::array::forcecast> arr) {
            auto buf = arr.request();
            return shannon::shannon_configurational_entropy(
                static_cast<const double*>(buf.ptr),
                static_cast<std::size_t>(buf.size));
        },
        py::arg("log_weights"),
        "Compute Shannon configurational entropy from unnormalized log-weights (bits).");

    m.def("shannon_entropy_from_probs",
        [](py::array_t<double, py::array::c_style | py::array::forcecast> arr) {
            auto buf = arr.request();
            return shannon::shannon_entropy_from_probs(
                static_cast<const double*>(buf.ptr),
                static_cast<std::size_t>(buf.size));
        },
        py::arg("probs"),
        "Compute Shannon entropy from a probability distribution (bits).");

    m.def("shannon_entropy_from_logprobs",
        [](py::array_t<double, py::array::c_style | py::array::forcecast> arr) {
            auto buf = arr.request();
            return shannon::shannon_entropy_from_logprobs(
                static_cast<const double*>(buf.ptr),
                static_cast<std::size_t>(buf.size));
        },
        py::arg("logprobs"),
        "Compute Shannon entropy from log-probabilities (bits).");

    // ── CollapseResult ──────────────────────────────────────────────────────

    py::class_<shannon::CollapseResult>(m, "CollapseResult")
        .def_readonly("entropy",      &shannon::CollapseResult::entropy)
        .def_readonly("window_mean",  &shannon::CollapseResult::window_mean)
        .def_readonly("window_std",   &shannon::CollapseResult::window_std)
        .def_readonly("delta",        &shannon::CollapseResult::delta)
        .def_readonly("z_score",      &shannon::CollapseResult::z_score)
        .def_readonly("collapsed",    &shannon::CollapseResult::collapsed)
        .def_readonly("token_index",  &shannon::CollapseResult::token_index)
        .def("__repr__", [](const shannon::CollapseResult& r) {
            return "<CollapseResult entropy=" + std::to_string(r.entropy) +
                   " delta=" + std::to_string(r.delta) +
                   " collapsed=" + (r.collapsed ? "True" : "False") + ">";
        });

    // ── CollapseDetector ────────────────────────────────────────────────────

    py::class_<shannon::CollapseDetector>(m, "CollapseDetector")
        .def(py::init<std::size_t, double>(),
             py::arg("window_size")    = shannon::kDefaultWindowSize,
             py::arg("threshold_bits") = shannon::kDefaultCollapseThreshold)
        .def("reset", &shannon::CollapseDetector::reset)
        .def("add_logits",
            [](shannon::CollapseDetector& self,
               py::array_t<double, py::array::c_style | py::array::forcecast> arr) {
                auto buf = arr.request();
                return self.add_logits(
                    static_cast<const double*>(buf.ptr),
                    static_cast<std::size_t>(buf.size));
            },
            py::arg("logits"))
        .def("add_probs",
            [](shannon::CollapseDetector& self,
               py::array_t<double, py::array::c_style | py::array::forcecast> arr) {
                auto buf = arr.request();
                return self.add_probs(
                    static_cast<const double*>(buf.ptr),
                    static_cast<std::size_t>(buf.size));
            },
            py::arg("probs"))
        .def("add_logprobs",
            [](shannon::CollapseDetector& self,
               py::array_t<double, py::array::c_style | py::array::forcecast> arr) {
                auto buf = arr.request();
                return self.add_logprobs(
                    static_cast<const double*>(buf.ptr),
                    static_cast<std::size_t>(buf.size));
            },
            py::arg("logprobs"))
        .def("set_callback", &shannon::CollapseDetector::set_callback,
             py::arg("callback"))
        .def_property_readonly("trace", &shannon::CollapseDetector::trace)
        .def_property_readonly("window_size", &shannon::CollapseDetector::window_size)
        .def_property_readonly("threshold_bits", &shannon::CollapseDetector::threshold_bits);

    // ── Constants ───────────────────────────────────────────────────────────

    m.attr("DEFAULT_WINDOW_SIZE")       = shannon::kDefaultWindowSize;
    m.attr("DEFAULT_COLLAPSE_THRESHOLD") = shannon::kDefaultCollapseThreshold;
}
