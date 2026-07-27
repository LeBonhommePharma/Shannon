"""Tests for scripts/shannon_installer.py — shipped install/update policy.

Drives the real module (resolve_source, source_kind, CLI --resolve-only)
and subprocess-runs the Unix wrapper for --help / path resolve. Does not
mock pip or reimplement install contract inside the test.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "scripts" / "shannon_installer.py"
UNIX_SH = ROOT / "scripts" / "install_shannon.sh"
WIN_PS1 = ROOT / "scripts" / "Install-Shannon.ps1"
MAC_SHANNON = ROOT / "scripts" / "shannon"


def _load_installer():
    assert INSTALLER.is_file(), INSTALLER
    spec = importlib.util.spec_from_file_location("shannon_installer", INSTALLER)
    assert spec and spec.loader
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def inst():
    return _load_installer()


# ── resolve_source / source_kind (shipped functions) ─────────────────────────


def test_resolve_pypi(inst):
    assert inst.resolve_source("pypi") == ["shannon-entropy"]
    assert inst.resolve_source("release") == ["shannon-entropy"]
    assert inst.source_kind("pypi") == "pypi"


def test_resolve_path_editable(inst):
    args = inst.resolve_source("path", repo_root=ROOT)
    assert args[0] == "-e"
    assert Path(args[1]) == ROOT.resolve()
    assert inst.source_kind("path") == "path"
    assert inst.resolve_source("editable", repo_root=ROOT) == args
    assert inst.resolve_source("clone", repo_root=ROOT) == args


def test_resolve_git_default(inst):
    args = inst.resolve_source("git")
    assert len(args) == 1
    assert args[0].startswith("git+https://")
    assert "LeBonhommePharma/Shannon" in args[0]
    assert inst.source_kind("git") == "git"
    assert inst.resolve_source("github") == args
    assert inst.resolve_source("head") == args


def test_resolve_git_url_passthrough(inst):
    url = "git+https://github.com/LeBonhommePharma/Shannon.git@main"
    assert inst.resolve_source(url) == [url]
    assert inst.source_kind(url) == "git"


def test_resolve_local_directory(inst, tmp_path):
    # Empty dir is not a package root → treated as requirement token.
    bare = tmp_path / "empty"
    bare.mkdir()
    assert inst.resolve_source(str(bare)) == [str(bare)]

    # Dir with pyproject → editable.
    pkg = tmp_path / "pkg"
    pkg.mkdir()
    (pkg / "pyproject.toml").write_text("[project]\nname='x'\n", encoding="utf-8")
    args = inst.resolve_source(str(pkg))
    assert args == ["-e", str(pkg.resolve())]


def test_resolve_path_missing_pyproject_raises(inst, tmp_path):
    with pytest.raises(FileNotFoundError):
        inst.resolve_source("path", repo_root=tmp_path)


def test_resolve_empty_raises(inst):
    with pytest.raises(ValueError):
        inst.resolve_source("  ")


# ── CLI --resolve-only (real entry point) ────────────────────────────────────


def test_cli_resolve_only_path():
    proc = subprocess.run(
        [sys.executable, str(INSTALLER), "--resolve-only", "--source", "path",
         "--repo-root", str(ROOT)],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    data = json.loads(proc.stdout.strip())
    assert data["kind"] == "path"
    assert data["pip_args"][0] == "-e"
    assert Path(data["pip_args"][1]) == ROOT.resolve()


def test_cli_resolve_only_git():
    proc = subprocess.run(
        [sys.executable, str(INSTALLER), "--resolve-only", "--source", "git"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    data = json.loads(proc.stdout.strip())
    assert data["kind"] == "git"
    assert data["pip_args"][0].startswith("git+")


def test_cli_help_exits_zero():
    proc = subprocess.run(
        [sys.executable, str(INSTALLER), "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0
    assert "source" in proc.stdout.lower()
    assert "update" in proc.stdout.lower()


# ── Shell / PowerShell surface (structural + help) ───────────────────────────


def test_unix_installer_script_exists_and_help():
    assert UNIX_SH.is_file()
    assert os.access(UNIX_SH, os.X_OK), "install_shannon.sh must be executable"
    proc = subprocess.run(
        ["bash", str(UNIX_SH), "--help"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    out = proc.stdout + proc.stderr
    assert "--path" in out
    assert "update" in out.lower() or "--update" in out


def test_unix_installer_delegates_to_python_module():
    text = UNIX_SH.read_text(encoding="utf-8")
    assert "shannon_installer.py" in text
    assert "--path" in text
    assert "--update" in text
    assert "--git" in text


def test_windows_ps1_modes_documented():
    assert WIN_PS1.is_file()
    text = WIN_PS1.read_text(encoding="utf-8")
    # Ship real modes — not a reimplementation of install logic.
    assert "shannon_installer.py" in text
    assert "Source" in text
    assert "path" in text
    assert "Update" in text
    assert "SkipTests" in text
    assert "git" in text.lower()
    assert "SHANNON_SKIP_CORE" in text


def test_macos_shannon_update_and_science_commands():
    assert MAC_SHANNON.is_file()
    text = MAC_SHANNON.read_text(encoding="utf-8")
    assert "update|upgrade" in text or "install|i|update" in text
    assert "science" in text
    assert "install_shannon.sh" in text
    proc = subprocess.run(
        ["bash", str(MAC_SHANNON), "help"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr
    assert "update" in proc.stdout.lower()
    assert "science" in proc.stdout.lower() or "install_shannon" in proc.stdout


# ── Live smoke against currently importable package ──────────────────────────


def test_venv_python_path_shape(inst):
    vdir = Path("fake-venv-path-math-only")  # not created; pure path shape
    py = inst.venv_python(vdir)
    if sys.platform == "win32":
        assert py.name == "python.exe"
        assert "Scripts" in py.parts
    else:
        assert py.name == "python"
        assert "bin" in py.parts


def test_ensure_venv_creates_and_reuses(inst, tmp_path):
    vdir = tmp_path / "v"
    py1 = inst.ensure_venv(sys.executable, vdir)
    assert Path(py1).is_file()
    # Second call reuses.
    py2 = inst.ensure_venv(sys.executable, vdir)
    assert py1 == py2
    # Interpreter runs.
    proc = subprocess.run(
        [py1, "-c", "import sys; print(sys.prefix)"],
        capture_output=True,
        text=True,
        check=True,
    )
    assert str(vdir) in proc.stdout or vdir.name in proc.stdout


def test_run_entropy_smoke_against_installed_or_dev_tree(inst):
    """Drive shipped run_entropy_smoke; skip only if package cannot import."""
    # Prefer repo python path so editable/dev tree works without prior pip.
    env = os.environ.copy()
    env["PYTHONPATH"] = str(ROOT / "python") + (
        os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else ""
    )
    env["SHANNON_SKIP_CORE"] = "1"
    # Invoke smoke via CLI --smoke-only so we exercise the entry point.
    proc = subprocess.run(
        [sys.executable, str(INSTALLER), "--smoke-only"],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )
    if proc.returncode != 0 and "No module named 'shannon'" in (proc.stderr + proc.stdout):
        pytest.skip("shannon not installed and not on PYTHONPATH for smoke")
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "entropy_smoke_ok" in proc.stdout
    assert "version=" in proc.stdout
