"""Version alignment across packaging sources (shipped check_version_align)."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_version_align.py"


def test_version_align_script_exit_zero():
    assert SCRIPT.is_file(), SCRIPT
    proc = subprocess.run(
        [sys.executable, str(SCRIPT), "--expect", "2.1.0"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "aligned" in proc.stdout


def test_package_version_matches_when_importable():
    # Drive real package if installed / on PYTHONPATH.
    sys.path.insert(0, str(ROOT / "python"))
    import shannon  # noqa: WPS433

    assert shannon.__version__ == "2.1.0"
