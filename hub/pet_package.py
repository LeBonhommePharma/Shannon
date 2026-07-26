#!/usr/bin/env python3
"""
pet_package.py — resolve Codex-compatible v2 pet packages (optional art).

Package layout (Codex interop)::

  <package-root>/<pet-id>/
    pet.json
    spritesheet.webp   # or path in pet.json spritesheetPath

Roots come from ``pet_paths`` (shared with agent memory). Agent-memory roots
are never treated as a spritesheet store. See ``SHANNON_PETS`` unified home.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence

import pet_paths

# Default search roots (first hit wins). Memory path is deliberately excluded.
DEFAULT_PET_ID = "shannon"


def default_codex_pets_roots() -> list[Path]:
    """Package roots via unified ``pet_paths`` policy."""
    return pet_paths.package_roots_excluding_memory(include_repo_mirrors=True)


def agent_memory_pets_root() -> Path:
    """Shannon agent-memory root — never used for spritesheet discovery."""
    return pet_paths.agent_memory_root()


@dataclass(frozen=True)
class PetPackage:
    """Resolved Codex v2 (or compatible) pet package metadata."""

    pet_id: str
    root: Path
    pet_json_path: Path
    spritesheet_path: Path
    sprite_version: int
    display_name: str = ""
    description: str = ""
    use_procedural: bool = False
    notes: tuple[str, ...] = field(default_factory=tuple)

    @property
    def is_v2(self) -> bool:
        return self.sprite_version >= 2

    def to_dict(self) -> dict:
        return {
            "pet_id": self.pet_id,
            "root": str(self.root),
            "pet_json_path": str(self.pet_json_path),
            "spritesheet_path": str(self.spritesheet_path),
            "sprite_version": self.sprite_version,
            "display_name": self.display_name,
            "description": self.description,
            "use_procedural": self.use_procedural,
            "is_v2": self.is_v2,
            "notes": list(self.notes),
        }


def _read_pet_json(path: Path) -> Optional[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    return data


def _package_from_dir(directory: Path, pet_id: str) -> Optional[PetPackage]:
    """Build a PetPackage if directory has valid pet.json + spritesheet."""
    if not directory.is_dir():
        return None
    meta_path = directory / "pet.json"
    if not meta_path.is_file():
        return None
    meta = _read_pet_json(meta_path)
    if meta is None:
        return None

    version = int(meta.get("spriteVersionNumber") or meta.get("sprite_version") or 0)
    sheet_rel = (
        meta.get("spritesheetPath")
        or meta.get("spritesheet_path")
        or "spritesheet.webp"
    )
    sheet = (directory / str(sheet_rel)).resolve()
    # Accept missing sheet only as soft-fail if version says v2 but path absent —
    # we still report found metadata only when the sheet exists (usable package).
    if not sheet.is_file():
        # Try common alternates
        for alt in ("spritesheet.webp", "spritesheet.png", "spritesheet.jpg"):
            cand = directory / alt
            if cand.is_file():
                sheet = cand.resolve()
                break
        else:
            return None

    display = str(meta.get("displayName") or meta.get("display_name") or pet_id)
    desc = str(meta.get("description") or "")
    pid = str(meta.get("id") or pet_id)
    notes: list[str] = []
    if version < 2:
        notes.append(f"spriteVersionNumber={version} (<2); atlas rows may be incomplete")
    return PetPackage(
        pet_id=pid,
        root=directory.resolve(),
        pet_json_path=meta_path.resolve(),
        spritesheet_path=sheet,
        sprite_version=version if version > 0 else 1,
        display_name=display,
        description=desc,
        use_procedural=False,
        notes=tuple(notes),
    )


def resolve_pet_package(
    pet_id: str = DEFAULT_PET_ID,
    *,
    roots: Optional[Sequence[Path]] = None,
    require_v2: bool = False,
) -> PetPackage:
    """Resolve a pet package by id, or return procedural fallback.

    Always succeeds: missing packages set ``use_procedural=True`` and empty paths.
    """
    pid = (pet_id or DEFAULT_PET_ID).strip() or DEFAULT_PET_ID
    search = list(roots) if roots is not None else default_codex_pets_roots()
    # Never search agent-memory root for sheets.
    memory = agent_memory_pets_root().resolve()
    filtered: list[Path] = []
    for r in search:
        try:
            rp = Path(r).expanduser().resolve()
        except OSError:
            continue
        if rp == memory:
            continue
        filtered.append(rp)

    for root in filtered:
        # Layout A: root/<pet_id>/pet.json
        candidate = root / pid
        pkg = _package_from_dir(candidate, pid)
        if pkg is not None:
            if require_v2 and not pkg.is_v2:
                continue
            return pkg
        # Layout B: root is itself the package dir (id matches)
        if root.name == pid:
            pkg = _package_from_dir(root, pid)
            if pkg is not None and (not require_v2 or pkg.is_v2):
                return pkg

    return PetPackage(
        pet_id=pid,
        root=Path(),
        pet_json_path=Path(),
        spritesheet_path=Path(),
        sprite_version=0,
        display_name=pid,
        description="",
        use_procedural=True,
        notes=("no Codex v2 package found; using procedural companion art",),
    )


def list_pet_packages(
    *,
    roots: Optional[Sequence[Path]] = None,
    require_v2: bool = True,
) -> list[PetPackage]:
    """List discoverable packages under the search roots."""
    search = list(roots) if roots is not None else default_codex_pets_roots()
    memory = agent_memory_pets_root().resolve()
    found: dict[str, PetPackage] = {}
    for root in search:
        try:
            rp = Path(root).expanduser()
        except OSError:
            continue
        if not rp.is_dir():
            continue
        try:
            if rp.resolve() == memory:
                continue
        except OSError:
            pass
        # Direct children as package dirs
        try:
            children = list(rp.iterdir())
        except OSError:
            children = []
        # Also allow root itself if it has pet.json
        scan = children + [rp]
        for child in scan:
            if not child.is_dir():
                continue
            pkg = _package_from_dir(child, child.name)
            if pkg is None:
                continue
            if require_v2 and not pkg.is_v2:
                continue
            found.setdefault(pkg.pet_id, pkg)
    return sorted(found.values(), key=lambda p: p.pet_id)
