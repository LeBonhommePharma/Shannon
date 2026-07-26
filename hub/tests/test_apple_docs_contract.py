"""Doc contracts for Apple-first README / platform docs.

Drives real repo files and the shipped ``scripts/shannon`` handrail so README
claims cannot drift from the operator path without a failing test.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
SHANNON_SH = REPO / "scripts" / "shannon"
README = REPO / "README.md"
MULTI = REPO / "docs" / "MULTI_DEVICE.md"
VERSION = (REPO / "VERSION").read_text(encoding="utf-8").strip()


def _readme() -> str:
    return README.read_text(encoding="utf-8")


def test_version_file_is_semver():
    assert re.fullmatch(r"\d+\.\d+\.\d+", VERSION), VERSION


def test_root_readme_apple_first_quick_start():
    text = _readme()
    assert "./scripts/shannon" in text
    assert "./scripts/shannon stop" in text
    assert "./scripts/shannon probe" in text
    # Platform entry points
    for needle in (
        "iOS/README.md",
        "iPad/README.md",
        "watchOS/README.md",
        "Pill/README.md",
        "docs/MULTI_DEVICE.md",
    ):
        assert needle in text, f"README must link {needle}"
    # Stale badges / package versions must not be the only story
    assert "tests-70%20pass" not in text
    assert "package_pill.sh 0.1.0" not in text


def test_platform_readmes_exist_with_build_and_test_how_to():
    required = {
        REPO / "Pill" / "README.md": ["./scripts/shannon", "swift test"],
        REPO / "iOS" / "README.md": ["xcodegen generate", "swift test", "iOS"],
        REPO / "iPad" / "README.md": ["xcodegen generate", "iPad"],
        REPO / "watchOS" / "README.md": ["watchOS", "xcodegen generate", "ShannonCore"],
        MULTI: ["CloudKit", "WatchConnectivity", "swift test", "Mac →"],
    }
    for path, needles in required.items():
        assert path.is_file(), path
        body = path.read_text(encoding="utf-8")
        for n in needles:
            assert n in body, f"{path.relative_to(REPO)} missing {n!r}"


def test_multi_device_documents_sync_direction_and_min_os():
    body = MULTI.read_text(encoding="utf-8")
    assert "CloudKit" in body
    assert "WatchConnectivity" in body
    # Direction of truth
    assert "Mac" in body and "iPhone" in body and "Watch" in body
    assert "iOS 17" in body or "iOS **17" in body or "iOS 17.0" in body
    assert "watchOS 10" in body or "watchOS **10" in body


def test_scripts_shannon_is_executable_handrail():
    assert SHANNON_SH.is_file(), SHANNON_SH
    text = SHANNON_SH.read_text(encoding="utf-8")
    for cmd in ("bootstrap", "app", "stop", "probe", "status", "help"):
        assert cmd in text, f"scripts/shannon missing {cmd}"
    # Shebang
    assert text.startswith("#!/")


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


def test_cask_version_is_pinned_semver_not_placeholder():
    cask = (REPO / "Casks" / "shannon-pill.rb").read_text(encoding="utf-8")
    ver = re.search(r'version\s+"([^"]+)"', cask)
    assert ver, "cask missing version"
    assert re.fullmatch(r"\d+\.\d+\.\d+", ver.group(1)), ver.group(1)
    sha = re.search(r'sha256\s+"([0-9a-f]{64})"', cask)
    assert sha, "cask missing sha256"
    assert sha.group(1) != "0" * 64, "cask must not use all-zero placeholder sha"


def test_package_pill_script_exists():
    script = REPO / "scripts" / "package_pill.sh"
    assert script.is_file()
    body = script.read_text(encoding="utf-8")
    assert "--install" in body
    assert "--update-cask" in body


@pytest.mark.parametrize(
    "rel",
    [
        "Packages/ShannonCore/Package.swift",
        "Packages/ShannonTheme/Package.swift",
        "Pill/Package.swift",
        "iOS/project.yml",
        "iPad/project.yml",
        "Pill/project.yml",
    ],
)
def test_apple_package_manifests_present(rel: str):
    assert (REPO / rel).is_file(), rel
