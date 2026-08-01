"""Repo index hygiene: junk classes stay untracked via shipped .gitignore.

Drives the real root `.gitignore` and `git ls-files` — not a reimplementation
of ignore matching. Fails if clangd cache, root audit notes, or one-off
screenshots re-enter the index.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GITIGNORE = ROOT / ".gitignore"

# Paths that must never reappear in the git index (product vs junk boundary).
FORBIDDEN_INDEX_PREFIXES = (
    ".cache/",
)
FORBIDDEN_INDEX_EXACT = frozenset(
    {
        "ENTROPY_AUDIT_2026-07-23.md",
        "SHANNON_AGENTPEEK_GAP.md",
        "SHANNON_PARITY_ROADMAP.md",
        "hub/docs/img/tests_passing.png",
    }
)

# Rules that must exist in the shipped .gitignore (substring match).
REQUIRED_GITIGNORE_SNIPPETS = (
    ".cache/",
    "SHANNON_PARITY_ROADMAP.md",
    "ENTROPY_AUDIT_*.md",
    "SHANNON_AGENTPEEK_GAP.md",
    "hub/docs/img/tests_passing.png",
    ".build/",
    "DerivedData/",
    ".pytest_cache/",
    ".venv/",
)


def _git_ls_files() -> list[str]:
    proc = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=str(ROOT),
        capture_output=True,
        check=True,
    )
    if not proc.stdout:
        return []
    return [p.decode() for p in proc.stdout.split(b"\0") if p]


def test_gitignore_documents_junk_classes():
    text = GITIGNORE.read_text(encoding="utf-8")
    missing = [s for s in REQUIRED_GITIGNORE_SNIPPETS if s not in text]
    assert not missing, f".gitignore missing required rules: {missing}"


def test_index_has_no_junk_classes():
    tracked = _git_ls_files()
    bad: list[str] = []
    for path in tracked:
        if path in FORBIDDEN_INDEX_EXACT:
            bad.append(path)
            continue
        for prefix in FORBIDDEN_INDEX_PREFIXES:
            if path.startswith(prefix):
                bad.append(path)
                break
    assert not bad, f"junk still tracked in index:\n" + "\n".join(bad[:40])


def test_product_assets_still_tracked():
    tracked = set(_git_ls_files())
    required = {
        "CMakeLists.txt",
        "README.md",
        "data/soft_contact_256.bin",
        "data/token_projection.bin",
        ".gitignore",
    }
    missing = sorted(required - tracked)
    assert not missing, f"product paths missing from index: {missing}"
    # At least one source file under each primary tree in this (Shannon CLI) repo.
    # Apple UI trees (Pill/, Packages/, …) live in LeBonhommePharma/ShannonUI.
    for prefix in ("src/", "python/", "hub/", "tests/", "archive/"):
        assert any(p.startswith(prefix) for p in tracked), f"no tracked files under {prefix}"


def test_check_ignore_covers_sample_junk_paths():
    samples = [
        ".cache/clangd/index/example.idx",
        "ENTROPY_AUDIT_2026-07-23.md",
        "SHANNON_AGENTPEEK_GAP.md",
        "hub/docs/img/tests_passing.png",
        "SHANNON_PARITY_ROADMAP.md",
    ]
    proc = subprocess.run(
        ["git", "check-ignore", "-v", *samples],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    for sample in samples:
        assert sample in proc.stdout, f"check-ignore did not cover {sample}:\n{proc.stdout}"
