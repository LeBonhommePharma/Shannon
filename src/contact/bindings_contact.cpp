// Copyright 2024-2026 Louis-Philippe Morency & Contributors
// SPDX-License-Identifier: MIT
//
// pybind11 bindings for the 256×256 soft contact matrix module.

#include <pybind11/pybind11.h>
#include <pybind11/numpy.h>
#include <pybind11/stl.h>

#include "contact/soft_contact_matrix.hpp"
#include "contact/atom_types.hpp"

namespace py = pybind11;
using namespace shannon::contact;

PYBIND11_MODULE(_shannon_contact_cpp, m) {
    m.doc() = "256×256 Soft Contact Interaction Matrix — C++ accelerated core";

    // ── Constants ───────────────────────────────────────────────────────────

    m.attr("NUM_ATOM_TYPES") = kNumAtomTypes;
    m.attr("MATRIX_SIZE")    = kMatrixSize;
    m.attr("MATRIX_BYTES")   = kMatrixBytes;

    // ── BaseAtomType enum ───────────────────────────────────────────────────

    py::enum_<BaseAtomType>(m, "BaseAtomType")
        .value("C_sp3",   BaseAtomType::C_sp3)
        .value("C_sp2",   BaseAtomType::C_sp2)
        .value("C_sp",    BaseAtomType::C_sp)
        .value("C_ar",    BaseAtomType::C_ar)
        .value("N_sp3",   BaseAtomType::N_sp3)
        .value("N_sp2",   BaseAtomType::N_sp2)
        .value("N_sp",    BaseAtomType::N_sp)
        .value("N_ar",    BaseAtomType::N_ar)
        .value("N_am",    BaseAtomType::N_am)
        .value("O_sp3",   BaseAtomType::O_sp3)
        .value("O_sp2",   BaseAtomType::O_sp2)
        .value("O_ar",    BaseAtomType::O_ar)
        .value("S_sp3",   BaseAtomType::S_sp3)
        .value("S_sp2",   BaseAtomType::S_sp2)
        .value("P_sp3",   BaseAtomType::P_sp3)
        .value("F_",      BaseAtomType::F_)
        .value("Cl_",     BaseAtomType::Cl_)
        .value("Br_",     BaseAtomType::Br_)
        .value("I_",      BaseAtomType::I_)
        .value("H_",      BaseAtomType::H_)
        .value("H_polar", BaseAtomType::H_polar)
        .value("Fe_",     BaseAtomType::Fe_)
        .value("Zn_",     BaseAtomType::Zn_)
        .value("Mg_",     BaseAtomType::Mg_)
        .value("Ca_",     BaseAtomType::Ca_)
        .value("Mn_",     BaseAtomType::Mn_)
        .value("Cu_",     BaseAtomType::Cu_)
        .value("Co_",     BaseAtomType::Co_)
        .value("Se_",     BaseAtomType::Se_)
        .value("Si_",     BaseAtomType::Si_);

    // ── ChargeBin enum ──────────────────────────────────────────────────────

    py::enum_<ChargeBin>(m, "ChargeBin")
        .value("StrongNeg", ChargeBin::StrongNeg)
        .value("WeakNeg",   ChargeBin::WeakNeg)
        .value("WeakPos",   ChargeBin::WeakPos)
        .value("StrongPos", ChargeBin::StrongPos);

    // ── Free functions ──────────────────────────────────────────────────────

    m.def("encode_atom_type",
        py::overload_cast<std::uint8_t, std::uint8_t, std::uint8_t>(
            &encode_atom_type),
        py::arg("base_type"), py::arg("charge_bin"), py::arg("hbond_flag"),
        "Encode base_type (0-31), charge_bin (0-3), hbond_flag (0-1) into uint8.");

    m.def("decode_base_type", &decode_base_type, py::arg("atom_type"),
        "Extract base atom type (bits 0-4) from encoded type.");

    m.def("decode_charge_bin", &decode_charge_bin, py::arg("atom_type"),
        "Extract charge bin (bits 5-6) from encoded type.");

    m.def("decode_hbond_flag", &decode_hbond_flag, py::arg("atom_type"),
        "Extract H-bond flag (bit 7) from encoded type.");

    m.def("bin_partial_charge",
        [](float q) { return static_cast<int>(bin_partial_charge(q)); },
        py::arg("charge"),
        "Bin a partial charge into 4 discrete levels (0-3).");

    // ── ContactPair ─────────────────────────────────────────────────────────

    py::class_<ContactPair>(m, "ContactPair")
        .def(py::init<>())
        .def(py::init([](uint8_t ti, uint8_t tj, float w) {
            return ContactPair{ti, tj, w};
        }), py::arg("type_i"), py::arg("type_j"), py::arg("weight") = 1.0f)
        .def_readwrite("type_i", &ContactPair::type_i)
        .def_readwrite("type_j", &ContactPair::type_j)
        .def_readwrite("weight", &ContactPair::weight);

    // ── SoftContactMatrix ───────────────────────────────────────────────────

    py::class_<SoftContactMatrix>(m, "SoftContactMatrix")
        .def(py::init<>())

        .def("load", [](SoftContactMatrix& self, const std::string& path) {
            self.load(path);
        }, py::arg("path"), "Load matrix from a binary file.")

        .def("save", [](const SoftContactMatrix& self, const std::string& path) {
            self.save(path);
        }, py::arg("path"), "Save matrix to a binary file with SCM1 header.")

        .def("load_from_numpy",
            [](SoftContactMatrix& self,
               py::array_t<float, py::array::c_style | py::array::forcecast> arr) {
                auto buf = arr.request();
                if (buf.size != static_cast<py::ssize_t>(kMatrixSize)) {
                    throw std::runtime_error(
                        "Expected array of size " + std::to_string(kMatrixSize) +
                        ", got " + std::to_string(buf.size));
                }
                self.load_from_buffer(static_cast<const float*>(buf.ptr));
            },
            py::arg("array"),
            "Load matrix from a numpy array of shape (256, 256) or (65536,).")

        // Zero-copy numpy view — shares memory with the matrix.
        // The py::cast(self) capsule prevents dangling if the matrix is
        // garbage-collected before the numpy array.
        .def("to_numpy",
            [](SoftContactMatrix& self) {
                return py::array_t<float>(
                    {static_cast<py::ssize_t>(kNumAtomTypes),
                     static_cast<py::ssize_t>(kNumAtomTypes)},
                    {static_cast<py::ssize_t>(sizeof(float) * kNumAtomTypes),
                     static_cast<py::ssize_t>(sizeof(float))},
                    self.data(),
                    py::cast(self));
            },
            "Return matrix as a (256, 256) numpy float32 view (zero-copy).")

        .def("lookup", &SoftContactMatrix::lookup,
            py::arg("type_i"), py::arg("type_j"),
            "O(1) interaction energy lookup.")

        .def("set", [](SoftContactMatrix& self, uint8_t ti, uint8_t tj, float val) {
            self.at(ti, tj) = val;
        }, py::arg("type_i"), py::arg("type_j"), py::arg("value"),
           "Set a matrix entry.")

        .def("symmetrize", &SoftContactMatrix::symmetrize,
            "Enforce symmetry: M[i][j] = M[j][i] = average.")

        .def("is_symmetric", &SoftContactMatrix::is_symmetric,
            py::arg("tol") = 1e-6f,
            "Check if matrix is symmetric within tolerance.")

        // ── Vectorized numpy contact methods (fast path) ────────────────────

        .def("score_contacts_np",
            [](const SoftContactMatrix& self,
               py::array_t<uint8_t, py::array::c_style | py::array::forcecast> ti,
               py::array_t<uint8_t, py::array::c_style | py::array::forcecast> tj,
               py::array_t<float, py::array::c_style | py::array::forcecast> w) {
                auto ti_buf = ti.request();
                auto tj_buf = tj.request();
                auto w_buf = w.request();
                if (ti_buf.size != tj_buf.size || ti_buf.size != w_buf.size) {
                    throw std::runtime_error(
                        "types_i, types_j, and weights must have equal length");
                }
                const auto n = static_cast<std::size_t>(ti_buf.size);
                float result;
                {
                    py::gil_scoped_release release;
                    result = self.score_contacts_arrays(
                        static_cast<const uint8_t*>(ti_buf.ptr),
                        static_cast<const uint8_t*>(tj_buf.ptr),
                        static_cast<const float*>(w_buf.ptr),
                        n);
                }
                return result;
            },
            py::arg("types_i"), py::arg("types_j"), py::arg("weights"),
            "Score contacts from numpy arrays (fast vectorized path).")

        .def("pose_activation_np",
            [](const SoftContactMatrix& self,
               py::array_t<uint8_t, py::array::c_style | py::array::forcecast> ti,
               py::array_t<uint8_t, py::array::c_style | py::array::forcecast> tj,
               py::array_t<float, py::array::c_style | py::array::forcecast> w) {
                auto ti_buf = ti.request();
                auto tj_buf = tj.request();
                auto w_buf = w.request();
                if (ti_buf.size != tj_buf.size || ti_buf.size != w_buf.size) {
                    throw std::runtime_error(
                        "types_i, types_j, and weights must have equal length");
                }
                const auto n = static_cast<std::size_t>(ti_buf.size);
                auto result = py::array_t<float>(
                    static_cast<py::ssize_t>(kNumAtomTypes));
                auto out_buf = result.request();
                {
                    py::gil_scoped_release release;
                    self.pose_activation_arrays(
                        static_cast<const uint8_t*>(ti_buf.ptr),
                        static_cast<const uint8_t*>(tj_buf.ptr),
                        static_cast<const float*>(w_buf.ptr),
                        n,
                        static_cast<float*>(out_buf.ptr));
                }
                return result;
            },
            py::arg("types_i"), py::arg("types_j"), py::arg("weights"),
            "Compute 256-dim pose activation from numpy arrays (fast path).")

        // ── Legacy ContactPair list methods (kept for compatibility) ────────

        .def("score_contacts",
            [](const SoftContactMatrix& self, py::list contacts_list) {
                std::vector<ContactPair> contacts;
                contacts.reserve(contacts_list.size());
                for (auto& item : contacts_list) {
                    contacts.push_back(item.cast<ContactPair>());
                }
                return self.score_contacts(contacts.data(), contacts.size());
            },
            py::arg("contacts"),
            "Score a list of ContactPair objects (prefer score_contacts_np).")

        .def("pose_activation",
            [](const SoftContactMatrix& self, py::list contacts_list) {
                std::vector<ContactPair> contacts;
                contacts.reserve(contacts_list.size());
                for (auto& item : contacts_list) {
                    contacts.push_back(item.cast<ContactPair>());
                }
                auto result = py::array_t<float>(
                    static_cast<py::ssize_t>(kNumAtomTypes));
                auto buf = result.request();
                self.pose_activation(
                    contacts.data(), contacts.size(),
                    static_cast<float*>(buf.ptr));
                return result;
            },
            py::arg("contacts"),
            "Compute 256-dim activation from ContactPair list (prefer pose_activation_np).")

        .def("project_to_sybyl",
            [](const SoftContactMatrix& self, std::size_t n_sybyl) {
                auto result = py::array_t<float>(
                    {static_cast<py::ssize_t>(n_sybyl),
                     static_cast<py::ssize_t>(n_sybyl)});
                auto buf = result.request();
                {
                    py::gil_scoped_release release;
                    self.project_to_sybyl(
                        static_cast<float*>(buf.ptr), n_sybyl);
                }
                return result;
            },
            py::arg("n_sybyl") = 32,
            "Project 256×256 to coarse SYBYL-parent resolution (default 32×32).");

    // ── SYBYL bridge functions ──────────────────────────────────────────────

    m.def("sybyl_parent", &sybyl_parent, py::arg("atom_type"),
        "Return the SYBYL parent index (base type) for a 256-type.");

    m.def("is_heteroatom_adjacent_aromatic",
        &is_heteroatom_adjacent_aromatic,
        py::arg("base_type"), py::arg("has_hetero_neighbor"),
        "Check if an aromatic carbon is adjacent to a heteroatom.");

    m.def("is_pi_bridging",
        &is_pi_bridging,
        py::arg("base_type"), py::arg("ring_count"),
        "Check if an aromatic atom bridges two or more rings.");
}
