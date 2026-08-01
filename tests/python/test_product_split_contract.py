"""Contract: Shannon ships as two named products — Shannon UI and Shannon CLI.

Drives real entry modules and production-path files so dual-product claims
cannot drift. Fails if:

* operator help/docs stop naming both products
* legacy dual status-item UI re-enters the production hub tree
* install/bootstrap/probe paths re-require the archived hub UI
* CLI help/status paths open GUI or stop being headless
* this CLI repo re-hosts extracted Apple UI trees as production
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SHANNON_SH = REPO / "scripts" / "shannon"
HUB = REPO / "hub"
ARCHIVE_LEGACY = REPO / "archive" / "legacy_agent_hub_ui"
README = REPO / "README.md"
SHANNON_UI_DOC = REPO / "docs" / "SHANNON_UI.md"

# Install / bootstrap / probe scripts that must not require AgentHubApp.
_OPERATOR_SCRIPTS = (
    SHANNON_SH,
    REPO / "scripts" / "package_pill.sh",
    REPO / "scripts" / "install_macos_app.sh",
    REPO / "scripts" / "install_shannon.sh",
)


def _run(
    *args: str,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    timeout: float = 45,
) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    merged.setdefault("SHANNON_FORCE_BUILD", "0")
    if env:
        merged.update(env)
    return subprocess.run(
        list(args),
        cwd=str(cwd or REPO),
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
        env=merged,
    )


# ── Dual-product identity in operator docs / help ────────────────────────────


def test_root_readme_names_both_products():
    text = README.read_text(encoding="utf-8")
    assert "Shannon UI" in text, "README must name Shannon UI"
    assert "Shannon CLI" in text, "README must name Shannon CLI"
    assert "./scripts/shannon" in text
    assert "shannon-monitor" in text
    assert "ShannonUI" in text or "docs/SHANNON_UI.md" in text


def test_shannon_ui_doc_present():
    assert SHANNON_UI_DOC.is_file()
    body = SHANNON_UI_DOC.read_text(encoding="utf-8")
    assert "Shannon UI" in body and "Shannon CLI" in body


def test_scripts_shannon_help_names_both_products():
    """Drive the real scripts/shannon help path (headless)."""
    proc = _run("bash", str(SHANNON_SH), "help")
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout + proc.stderr
    assert "Shannon UI" in out
    assert "Shannon CLI" in out
    assert "headless" in out.lower() or "no AppKit" in out or "no GUI" in out.lower()


def test_scripts_shannon_help_is_stable_across_two_runs():
    outs: list[str] = []
    for _ in range(2):
        proc = _run("bash", str(SHANNON_SH), "help")
        assert proc.returncode == 0, proc.stderr + proc.stdout
        outs.append(proc.stdout)
    assert "Shannon CLI" in outs[0] and "Shannon CLI" in outs[1]
    assert "Shannon UI" in outs[0] and "Shannon UI" in outs[1]


def test_python_cli_help_names_shannon_cli():
    proc = _run(sys.executable, "-m", "shannon.cli", "--help")
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout + proc.stderr
    assert "Shannon CLI" in out


def test_hub_agent_manager_help_names_shannon_cli():
    env = {"PYTHONPATH": str(HUB) + os.pathsep + os.environ.get("PYTHONPATH", "")}
    proc = _run(sys.executable, "-m", "agent_manager", "--help", env=env)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    assert "Shannon CLI" in (proc.stdout + proc.stderr)


def test_hub_readme_names_shannon_cli():
    hub = (HUB / "README.md").read_text(encoding="utf-8")
    assert "Shannon CLI" in hub
    assert "archive/legacy_agent_hub_ui" in hub


# ── Legacy dual status-item UI is non-production ─────────────────────────────


def test_legacy_agent_hub_ui_archived_not_under_hub():
    assert not (HUB / "AgentHubApp.swift").exists()
    assert not (HUB / "Pet").exists()
    assert (ARCHIVE_LEGACY / "AgentHubApp.swift").is_file()
    assert (ARCHIVE_LEGACY / "Pet").is_dir()
    assert (ARCHIVE_LEGACY / "README.md").is_file()
    archive_readme = (ARCHIVE_LEGACY / "README.md").read_text(encoding="utf-8")
    assert "Shannon UI" in archive_readme and "Shannon CLI" in archive_readme


def test_production_operator_scripts_do_not_require_agent_hub_app():
    for path in _OPERATOR_SCRIPTS:
        if not path.is_file():
            continue
        body = path.read_text(encoding="utf-8")
        assert "hub/AgentHubApp" not in body, f"{path.relative_to(REPO)} still references hub/AgentHubApp"
        assert not re.search(
            r"(?:open|swiftc|xcodebuild).{0,40}AgentHubApp",
            body,
        ), f"{path.relative_to(REPO)} launches/builds AgentHubApp"


def test_package_and_formula_do_not_ship_legacy_hub_ui():
    formula = (REPO / "Formula" / "shannon.rb").read_text(encoding="utf-8")
    cask = (REPO / "Casks" / "shannon-pill.rb").read_text(encoding="utf-8")
    assert "AgentHubApp" not in formula
    assert "AgentHubApp" not in cask
    assert "Shannon CLI" in formula or "shannon-agent" in formula
    assert "Shannon UI" in cask


def test_extracted_apple_ui_not_required_in_this_repo():
    """Shannon UI sources live in ShannonUI; this CLI repo must not re-host them."""
    for rel in ("Pill/Package.swift", "iOS/project.yml", "Packages/ShannonCore/Package.swift"):
        assert not (REPO / rel).is_file(), f"{rel} should not be production here"


# ── Headless CLI status / probe (no GUI launch) ──────────────────────────────


def test_scripts_shannon_status_is_headless():
    before = _pgrep_names()
    proc = _run("bash", str(SHANNON_SH), "status", timeout=60)
    after = _pgrep_names()
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout + proc.stderr
    assert "Shannon" in out
    new = after - before
    assert "AgentHubApp" not in new
    if "ShannonPill" not in before:
        assert "ShannonPill" not in new


def test_scripts_shannon_status_two_runs_consistent():
    for _ in range(2):
        proc = _run("bash", str(SHANNON_SH), "status", timeout=60)
        assert proc.returncode == 0, proc.stderr + proc.stdout
        assert "Shannon" in (proc.stdout + proc.stderr)


def _pgrep_names() -> set[str]:
    names: set[str] = set()
    proc = subprocess.run(
        ["pgrep", "-l", "-x", "ShannonPill"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        names.add("ShannonPill")
    proc2 = subprocess.run(
        ["pgrep", "-l", "AgentHub"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc2.returncode == 0 and "AgentHub" in (proc2.stdout or ""):
        names.add("AgentHubApp")
    return names


def test_shannon_cli_main_help_via_subprocess_twice():
    for _ in range(2):
        proc = _run(sys.executable, "-m", "shannon.cli", "--help")
        assert proc.returncode == 0, proc.stderr + proc.stdout
        assert "Shannon CLI" in (proc.stdout + proc.stderr)


def test_shannon_cli_info_subcommand_headless():
    proc = _run(sys.executable, "-m", "shannon.cli", "info", timeout=60)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout + proc.stderr
    assert "Shannon" in out
