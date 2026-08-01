"""Doc contracts for dual-product README / ShannonUI pointer docs.

Drives real repo files and the shipped ``scripts/shannon`` handrail so operator
claims cannot drift after the Shannon UI extract to LeBonhommePharma/ShannonUI.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SHANNON_SH = REPO / "scripts" / "shannon"
README = REPO / "README.md"
SHANNON_UI_DOC = REPO / "docs" / "SHANNON_UI.md"
MULTI = REPO / "docs" / "MULTI_DEVICE.md"
VERSION = (REPO / "VERSION").read_text(encoding="utf-8").strip()


def _readme() -> str:
    return README.read_text(encoding="utf-8")


def test_version_file_is_semver():
    assert re.fullmatch(r"\d+\.\d+\.\d+", VERSION), VERSION


def test_root_readme_names_products_and_shannonui():
    text = _readme()
    assert "./scripts/shannon" in text
    assert "Shannon UI" in text
    assert "Shannon CLI" in text
    assert "ShannonUI" in text or "shannonui" in text.lower()
    assert "docs/SHANNON_UI.md" in text
    # Stale badges / package versions must not be the only story
    assert "tests-70%20pass" not in text
    assert "package_pill.sh 0.1.0" not in text
    # Local Apple trees were extracted — do not claim in-tree Pill/iOS READMEs.
    assert "Pill/README.md" not in text
    assert "iOS/README.md" not in text


def test_shannon_ui_doc_maps_extract():
    assert SHANNON_UI_DOC.is_file()
    body = SHANNON_UI_DOC.read_text(encoding="utf-8")
    assert "LeBonhommePharma/ShannonUI" in body or "github.com/LeBonhommePharma/ShannonUI" in body
    assert "Shannon UI" in body
    assert "Shannon CLI" in body
    for moved in ("Pill/", "iOS/", "iPad/", "watchOS/", "Packages/"):
        assert moved in body, f"SHANNON_UI.md must document move of {moved}"


def test_multi_device_documents_sync_direction_and_min_os():
    if not MULTI.is_file():
        pytest.skip("docs/MULTI_DEVICE.md not present in this tree")
    body = MULTI.read_text(encoding="utf-8")
    assert "CloudKit" in body
    assert "WatchConnectivity" in body
    assert "Mac" in body and "iPhone" in body and "Watch" in body
    assert "iOS 17" in body or "iOS **17" in body or "iOS 17.0" in body
    assert "watchOS 10" in body or "watchOS **10" in body


def test_scripts_shannon_is_executable_handrail():
    assert SHANNON_SH.is_file(), SHANNON_SH
    text = SHANNON_SH.read_text(encoding="utf-8")
    for cmd in ("bootstrap", "app", "stop", "probe", "status", "help"):
        assert cmd in text, f"scripts/shannon missing {cmd}"
    assert text.startswith("#!/")
    # Must resolve external Shannon UI, not hard-require in-tree Pill only.
    assert "SHANNON_UI" in text or "ShannonUI" in text
    assert "resolve_pill_root" in text or "SHANNON_UI_ROOT" in text


def test_scripts_shannon_help_runs():
    """Drive the real CLI help path (no GUI)."""
    proc = subprocess.run(
        ["bash", str(SHANNON_SH), "help"],
        cwd=str(REPO),
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    out = proc.stdout + proc.stderr
    assert "probe" in out.lower() or "stop" in out.lower()
    assert "shannon" in out.lower()
    assert "Shannon UI" in out
    assert "Shannon CLI" in out


def test_cask_version_is_pinned_semver_not_placeholder():
    cask = (REPO / "Casks" / "shannon-pill.rb").read_text(encoding="utf-8")
    ver = re.search(r'version\s+"([^"]+)"', cask)
    assert ver, "cask missing version"
    assert re.fullmatch(r"\d+\.\d+\.\d+", ver.group(1)), ver.group(1)
    sha = re.search(r'sha256\s+"([0-9a-f]{64})"', cask)
    assert sha, "cask missing sha256"
    assert sha.group(1) != "0" * 64, "cask must not use all-zero placeholder sha"
    assert "Shannon UI" in cask


def test_package_pill_script_exists_or_is_documented():
    """Packaging may remain here as a helper; UI sources are in ShannonUI."""
    script = REPO / "scripts" / "package_pill.sh"
    doc = SHANNON_UI_DOC.read_text(encoding="utf-8")
    if script.is_file():
        body = script.read_text(encoding="utf-8")
        assert "--install" in body
    else:
        assert "ShannonUI" in doc


def test_apple_package_manifests_not_required_in_cli_repo():
    """After extract, Swift package manifests must not be required here."""
    for rel in (
        "Packages/ShannonCore/Package.swift",
        "Packages/ShannonTheme/Package.swift",
        "Pill/Package.swift",
        "iOS/project.yml",
    ):
        assert not (REPO / rel).is_file(), f"{rel} should live in ShannonUI, not this repo"
