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

_UNIX_BASH = pytest.mark.skipif(
    sys.platform == "win32",
    reason=(
        "bash operator scripts; Windows GitHub runners expose a WSL stub "
        "with no distro installed"
    ),
)

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
    # Private sibling — must not pretend anonymous HTTPS always works.
    assert "private" in body.lower()
    assert "SHANNON_UI_CHECKOUT_TOKEN" in body
    assert (
        "git@github.com:LeBonhommePharma/ShannonUI" in body
        or "gh repo clone" in body
    )


@_UNIX_BASH
def test_scripts_shannon_help_names_both_products():
    """Drive the real scripts/shannon help path (headless)."""
    proc = _run("bash", str(SHANNON_SH), "help")
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout + proc.stderr
    assert "Shannon UI" in out
    assert "Shannon CLI" in out
    assert "headless" in out.lower() or "no AppKit" in out or "no GUI" in out.lower()


@_UNIX_BASH
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


def test_hub_agent_manager_help_is_cp1252_encodable():
    """Windows hosted runners default to cp1252; --help must not raise."""
    env = {"PYTHONPATH": str(HUB) + os.pathsep + os.environ.get("PYTHONPATH", "")}
    proc = _run(sys.executable, "-m", "agent_manager", "--help", env=env)
    assert proc.returncode == 0, proc.stderr + proc.stdout
    (proc.stdout + proc.stderr).encode("cp1252")


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


def test_package_pill_and_swarm_resolve_or_skip_shannon_ui():
    """Shipped packaging + swarm scripts must use lib_shannon_ui resolution."""
    lib = (REPO / "scripts" / "lib_shannon_ui.sh").read_text(encoding="utf-8")
    pkg = (REPO / "scripts" / "package_pill.sh").read_text(encoding="utf-8")
    swarm = (REPO / "scripts" / "platform_swarm.sh").read_text(encoding="utf-8")
    apple = (REPO / "scripts" / "test_apple_platforms.sh").read_text(encoding="utf-8")
    assert "resolve_shannon_ui" in lib
    assert "SHANNON_UI_ROOT" in lib
    for body, name in ((pkg, "package_pill"), (swarm, "platform_swarm"), (apple, "test_apple_platforms")):
        assert "lib_shannon_ui" in body or "resolve_shannon_ui" in body, name
    assert 'PILL_DIR="${REPO_ROOT}/Pill"' not in pkg
    if sys.platform == "win32":
        pytest.skip(
            "bash package_pill.sh; Windows GitHub runners expose a WSL stub "
            "with no distro installed"
        )
    # package_pill without UI must fail with a clear message (drive real script).
    proc = _run(
        "bash",
        str(REPO / "scripts" / "package_pill.sh"),
        "--help",
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    # Force missing UI for a real resolve failure (not --help).
    env = os.environ.copy()
    env["SHANNON_UI_ROOT"] = "/nonexistent/shannon-ui-missing-for-test"
    # Unset accidental sibling by pointing REPO-local resolve only via env.
    proc2 = subprocess.run(
        ["bash", str(REPO / "scripts" / "package_pill.sh"), "9.9.9"],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env=env,
    )
    assert proc2.returncode != 0, "package_pill must fail when ShannonUI is missing"
    err = proc2.stdout + proc2.stderr
    assert "Shannon UI" in err or "ShannonUI" in err or "SHANNON_UI_ROOT" in err


# ── Headless CLI status / probe (no GUI launch) ──────────────────────────────


@_UNIX_BASH
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


@_UNIX_BASH
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
