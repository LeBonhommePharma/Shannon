# Copyright 2024-2026 Louis-Philippe Morency & Contributors
# SPDX-License-Identifier: MIT
"""Pytest helpers for the Shannon pure-Python suite.

`pyproject.toml` sets `pythonpath = ["python"]` so in-process imports work
without `pip install -e .`. Subprocess tests (`python -m shannon.cli`, version
align scripts) still need `PYTHONPATH` so the child interpreter finds the
package tree (ENH-009).
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]
_PYTHON_SRC = _REPO_ROOT / "python"


@pytest.fixture(scope="session", autouse=True)
def _ensure_python_package_on_path() -> None:
    """Prepend repo `python/` to PYTHONPATH for subprocess children."""
    if not _PYTHON_SRC.is_dir():
        return
    src = str(_PYTHON_SRC)
    current = os.environ.get("PYTHONPATH", "")
    parts = [p for p in current.split(os.pathsep) if p]
    if src not in parts:
        os.environ["PYTHONPATH"] = os.pathsep.join([src, *parts]) if parts else src
