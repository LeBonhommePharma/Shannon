"""Build script for the shannon-entropy Python package.

The accelerated ``shannon._core`` extension is **optional**:
- Built when pybind11 + a C++20 compiler + sources are available and compile succeeds.
- Skipped cleanly (pure-Python / Numba fallback) when any of those are missing or
  the compile fails. ``pip install shannon-entropy`` must always succeed.

Set ``SHANNON_SKIP_CORE=1`` to force pure-Python packaging (used for the
universal ``py3-none-any`` wheel on PyPI).
"""

from __future__ import annotations

import os
import sys
import warnings
from pathlib import Path
from typing import List, Optional, Tuple

from setuptools import Extension, setup
from setuptools.command.build_ext import build_ext as _build_ext

ROOT = Path(__file__).resolve().parent

# C++ sources for shannon._core (paths relative to repo / sdist root).
_CORE_SOURCES = [
    "src/bindings.cpp",
    "src/shannon.cpp",
    "src/energy_matrix.cpp",
    "src/fast_optics.cpp",
]

_CORE_HEADERS_GLOBS = [
    "src/*.h",
    "src/*.hpp",
    "src/shannon/*.hpp",
]


def _skip_core_requested() -> bool:
    return os.environ.get("SHANNON_SKIP_CORE", "").lower() in ("1", "true", "yes")


def _core_sources_available() -> bool:
    return all((ROOT / rel).is_file() for rel in _CORE_SOURCES)


def _cxx_std_args() -> List[str]:
    if os.name == "nt":
        return ["/O2", "/std:c++20", "/EHsc"]
    return ["-std=c++20", "-O3"]


class optional_build_ext(_build_ext):
    """Build extensions, but never fail the whole install if compile breaks.

    Extensions that are skipped or fail to compile are removed so setuptools
    does not package a missing ``.so`` / ``.pyd``. When nothing is built,
    ``ext_modules`` is cleared so ``bdist_wheel`` emits a pure ``py3-none-any``
    wheel (required for portable PyPI installs).
    """

    def build_extensions(self) -> None:
        if not self.extensions:
            return
        requested = list(self.extensions)
        kept: List[Extension] = []
        for ext in requested:
            try:
                self.build_extension(ext)
            except Exception as exc:  # pragma: no cover - platform/compiler dependent
                warnings.warn(
                    f"Failed to build extension {ext.name} ({exc}). Skipping.",
                    stacklevel=2,
                )
                continue
            try:
                built = Path(self.get_ext_fullpath(ext.name))
            except Exception:
                built = None
            if built is not None and built.is_file():
                kept.append(ext)
            else:
                self.announce(
                    f"skipping package of {ext.name} (no binary produced)",
                    level=2,
                )
        self.extensions = kept
        if not kept:
            self.distribution.ext_modules = []
            if any(getattr(e, "name", "") == "shannon._core" for e in requested):
                warnings.warn(
                    "shannon._core was not built. Installing pure-Python fallback only. "
                    "Install a C++20 compiler + pybind11 for the accelerated path.",
                    stacklevel=2,
                )

    def build_extension(self, ext: Extension) -> None:
        if ext.name == "shannon._core":
            if not self._prepare_core_extension(ext):
                self.announce(
                    "skipping shannon._core (sources/deps unavailable)",
                    level=2,
                )
                return
        try:
            super().build_extension(ext)
        except Exception as exc:  # pragma: no cover
            warnings.warn(
                f"Failed to build extension {ext.name}: {exc}. Skipping.",
                stacklevel=2,
            )

    def _prepare_core_extension(self, ext: Extension) -> bool:
        if _skip_core_requested():
            warnings.warn(
                "SHANNON_SKIP_CORE set — installing pure-Python package only.",
                stacklevel=2,
            )
            return False

        try:
            import pybind11
        except ImportError:
            warnings.warn(
                "pybind11 not found. The accelerated _core extension will be skipped.",
                stacklevel=2,
            )
            return False

        if not _core_sources_available():
            warnings.warn(
                "C++ sources for shannon._core not found "
                f"(expected under {ROOT / 'src'}). "
                "Installing pure-Python fallback only.",
                stacklevel=2,
            )
            return False

        define_macros: List[Tuple[str, Optional[str]]] = list(ext.define_macros or [])
        if os.name == "nt":
            for macro in (
                ("_CRT_SECURE_NO_WARNINGS", "1"),
                ("_USE_MATH_DEFINES", "1"),
                ("NOMINMAX", "1"),
            ):
                if not any(k == macro[0] for k, _ in define_macros):
                    define_macros.append(macro)

        ext.sources = list(_CORE_SOURCES)
        ext.include_dirs = [
            str(ROOT / "src"),
            pybind11.get_include(),
        ]
        ext.define_macros = define_macros
        ext.language = "c++"
        if not ext.extra_compile_args:
            ext.extra_compile_args = _cxx_std_args()
        return True


def _placeholder_extension_modules() -> List[Extension]:
    """Declare _core with relative sources; real flags filled at build time."""
    if _skip_core_requested():
        warnings.warn(
            "SHANNON_SKIP_CORE set — installing pure-Python package only.",
            stacklevel=2,
        )
        return []

    if not _core_sources_available():
        return []

    try:
        import pybind11  # noqa: F401
    except ImportError:
        # During build isolation pybind11 is in build-system.requires and will
        # be available when build_ext actually runs. Still declare the extension.
        pass

    return [
        Extension(
            "shannon._core",
            sources=list(_CORE_SOURCES),
            include_dirs=["src"],
            language="c++",
            extra_compile_args=_cxx_std_args(),
        )
    ]


def _read_version() -> str:
    """Parse version without importing the package (avoids numpy at build time)."""
    # Prefer pyproject static field for packaging consistency.
    pyproject = ROOT / "pyproject.toml"
    if pyproject.is_file():
        in_project = False
        for line in pyproject.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                in_project = s == "[project]"
                continue
            if in_project and s.startswith("version") and "=" in s:
                return s.split("=", 1)[1].strip().strip("\"'")

    init_file = ROOT / "python" / "shannon" / "__init__.py"
    for line in init_file.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("__version__") and "=" in stripped:
            rhs = stripped.split("=", 1)[1].strip()
            return rhs.strip().strip("\"'")
    return "0.0.0"


# Metadata primarily lives in pyproject.toml. Explicit name/version here are a
# hard fallback for legacy pip/setuptools that do not fully apply PEP 621.
#
# Use a dedicated build base so setuptools never collides with the CMake
# ``build/`` tree (which would otherwise package libgtest.a into the wheel).
setup(
    name="shannon-entropy",
    version=_read_version(),
    package_dir={"": "python"},
    packages=["shannon", "shannon.integrations", "shannon_contact"],
    ext_modules=_placeholder_extension_modules(),
    cmdclass={
        "build_ext": optional_build_ext,
    },
    zip_safe=False,
    options={
        "build": {"build_base": ".pybuild"},
    },
)
