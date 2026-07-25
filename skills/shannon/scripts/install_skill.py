#!/usr/bin/env python3
"""Install the Shannon skill into host agent skill directories.

Copies (or symlinks) skills/shannon → Claude / Codex / Grok / OpenCode / agents
trees so TUIs load the same handrail.

Usage
-----
  python3 skills/shannon/scripts/install_skill.py
  python3 skills/shannon/scripts/install_skill.py --symlink
  python3 skills/shannon/scripts/install_skill.py --dry-run
"""

from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path


def repo_root() -> Path:
    # skills/shannon/scripts/thisfile → repo
    return Path(__file__).resolve().parents[3]


def skill_source(root: Path) -> Path:
    return root / "skills" / "shannon"


def candidate_targets(root: Path, home: Path) -> list[Path]:
    """Ordered install destinations (project first, then user hosts)."""
    paths = [
        root / ".claude" / "skills" / "shannon",
        root / ".grok" / "skills" / "shannon",
        root / ".agents" / "skills" / "shannon",
        home / ".claude" / "skills" / "shannon",
        home / ".codex" / "skills" / "shannon",
        home / ".grok" / "skills" / "shannon",
        home / ".config" / "opencode" / "skills" / "shannon",
        home / ".opencode" / "skills" / "shannon",
    ]
    # Sibling FlexAIDdS when present
    flex = home / "Projects" / "FlexAIDdS"
    if flex.is_dir():
        paths.append(flex / ".agents" / "skills" / "shannon")
        paths.append(flex / ".claude" / "skills" / "shannon")
        paths.append(flex / ".grok" / "skills" / "shannon")
    return paths


def should_install(path: Path, *, force_user: bool) -> bool:
    """Only write under trees that already exist (or project-local)."""
    # Always allow project-local .claude/.grok/.agents under the Shannon repo.
    parts = path.parts
    if ".claude" in parts or ".grok" in parts or ".agents" in parts:
        # If parent skills dir exists or we are inside the Shannon repo project
        parent = path.parent
        if parent.exists() or force_user:
            return True
        # Create project-local trees even if missing
        try:
            # project root is parents[2] for .claude/skills/shannon
            if (path.parents[2] / "skills" / "shannon").is_dir():
                return True
        except IndexError:
            pass
    # User host: only if skills parent or grandparent config exists
    if path.parent.exists() or path.parent.parent.exists():
        return True
    return force_user


def install_one(
    src: Path,
    dest: Path,
    *,
    symlink: bool,
    dry_run: bool,
) -> str:
    # Dry-run always reports the planned destination first (even if already linked).
    if dry_run:
        try:
            same = dest.exists() and dest.resolve() == src.resolve()
        except OSError:
            same = False
        if same:
            return f"dry-run (already present) → {dest}"
        return f"dry-run → {dest}"
    if dest.exists() or dest.is_symlink():
        try:
            if dest.resolve() == src.resolve():
                return f"skip self {dest}"
        except OSError:
            pass
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() or dest.is_symlink():
        if dest.is_symlink() or dest.is_file():
            dest.unlink()
        else:
            shutil.rmtree(dest)
    if symlink:
        dest.symlink_to(src, target_is_directory=True)
        return f"symlink {dest} → {src}"
    shutil.copytree(src, dest)
    return f"copy → {dest}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Install Shannon skill into agent hosts")
    ap.add_argument("--symlink", action="store_true", help="symlink instead of copy")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true", help="create host trees if missing")
    ap.add_argument("--home", default=str(Path.home()), help="override home (tests)")
    args = ap.parse_args(argv)

    root = repo_root()
    src = skill_source(root)
    if not (src / "SKILL.md").is_file():
        print(f"missing skill source: {src}", file=sys.stderr)
        return 1

    home = Path(args.home).expanduser()
    results = []
    for dest in candidate_targets(root, home):
        if not should_install(dest, force_user=args.force):
            # Still install project-local always
            if root in dest.parents or dest.is_relative_to(root):
                pass
            else:
                results.append(f"skip (no host tree): {dest}")
                continue
        # Always install into repo-local skill dirs
        try:
            rel_ok = dest.is_relative_to(root)
        except AttributeError:
            rel_ok = str(dest).startswith(str(root))
        if not rel_ok and not should_install(dest, force_user=args.force):
            results.append(f"skip: {dest}")
            continue
        if not rel_ok and not (dest.parent.exists() or dest.parent.parent.exists() or args.force):
            results.append(f"skip (host absent): {dest}")
            continue
        msg = install_one(src, dest, symlink=args.symlink, dry_run=args.dry_run)
        results.append(msg)

    for line in results:
        print(line)
    # Success if we installed, dry-ran, or confirmed already-present (skip self).
    ok = any(
        line.startswith(("copy", "symlink", "dry-run", "skip self"))
        for line in results
    )
    return 0 if ok else 1


if __name__ == "__main__":
    # Python 3.9 compat: is_relative_to may be missing — handled above.
    raise SystemExit(main())
