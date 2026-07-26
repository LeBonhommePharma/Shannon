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


# Hardcoded suite sizes go stale the moment a test is added. Apple platform docs
# must point operators at `swift test` instead of inventing inventory.
_FROZEN_SUITE_COUNT = re.compile(
    r"(?i)(?:"
    r"\b\d{1,4}\s+tests\b"  # "78 tests", "737 tests"
    r"|\bTests/\w+/?\s+\d{1,4}\s+tests\b"
    r")"
)

_APPLE_DOC_PATHS = (
    REPO / "docs" / "MULTI_DEVICE.md",
    REPO / "Pill" / "README.md",
    REPO / "iOS" / "README.md",
    REPO / "iPad" / "README.md",
    REPO / "watchOS" / "README.md",
)


def test_apple_docs_forbid_hardcoded_suite_counts():
    """Production docs must not freeze XCTest inventory numbers."""
    offenders: list[str] = []
    for path in _APPLE_DOC_PATHS:
        body = path.read_text(encoding="utf-8")
        for m in _FROZEN_SUITE_COUNT.finditer(body):
            # Allow explicit "not frozen" / authoritative wording nearby is still
            # a count claim if digits appear — ban all digit+"tests" in these files.
            line_no = body.count("\n", 0, m.start()) + 1
            offenders.append(f"{path.relative_to(REPO)}:{line_no}: {m.group(0)!r}")
    assert not offenders, (
        "Hardcoded suite sizes drift; use 'swift test is authoritative' instead:\n"
        + "\n".join(offenders)
    )


def test_apple_docs_point_at_swift_test_authority():
    multi = MULTI.read_text(encoding="utf-8")
    pill = (REPO / "Pill" / "README.md").read_text(encoding="utf-8")
    assert "swift test" in multi
    assert "swift test" in pill
    assert "authoritative" in pill.lower() or "not frozen" in multi.lower()


def test_ipad_readme_labels_core_vs_theme_correctly():
    body = (REPO / "iPad" / "README.md").read_text(encoding="utf-8")
    low = body.lower()
    assert "shannoncore" in low and "shannontheme" in low
    # Core = multi-device model / policies; Theme = design tokens only.
    assert "multi-device model" in low
    assert "design tokens only" in low or "design tokens" in low
    # Order: Core how-to before Theme how-to.
    core_i = low.find("packages/shannoncore")
    theme_i = low.find("packages/shannontheme")
    assert 0 <= core_i < theme_i, "ShannonCore how-to should appear before ShannonTheme"
    before_theme = low[max(0, theme_i - 120) : theme_i]
    assert "token" in before_theme, before_theme
    # Theme line must explicitly deny being the multi-device model.
    assert "not the multi-device model" in before_theme or "design tokens only" in before_theme


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
