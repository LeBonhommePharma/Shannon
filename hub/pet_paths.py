#!/usr/bin/env python3
"""
pet_paths.py — single path policy for both pet systems (Python side).

Mirrors PillCore ``PetPaths`` (Swift). Operators: see also Pill/README.md
"Pet paths (operators)".

  packages  Codex-compatible v2 art
            <root>/<pet-id>/{pet.json,spritesheet.webp}

  agents    Shannon per-agent memory
            <root>/<agent_id>/{state.json,memory.md,history.jsonl,config.json}

Defaults (back-compat, no env required)::

  packages → ~/.codex/pets
  agents   → ~/.shannon/pets

Unified home (optional) — one tree for both roles::

  export SHANNON_PETS="$HOME/.codex/pets"
  # or absolute: export SHANNON_PETS=/Users/you/.codex/pets

    packages → $SHANNON_PETS  (and $SHANNON_PETS/packages if that directory exists)
    agents   → $SHANNON_PETS/agents

  Example after ``export SHANNON_PETS=/Users/you/.codex/pets``::

    /Users/you/.codex/pets/shannon/pet.json       # package
    /Users/you/.codex/pets/agents/codex/state.json  # agent memory

Narrow overrides:
  SHANNON_CODEX_PETS  — packages only
  CODEX_HOME          — packages under $CODEX_HOME/pets
  SHANNON_PETS_AGENTS — agents only
  SHANNON_LOG_DIR / FLEXAIDDS_LOG_DIR — Shannon home (agents → …/pets
                        when no SHANNON_PETS / SHANNON_PETS_AGENTS)

Agent-memory roots are never used as spritesheet stores. Migrating agent
memory onto ``$SHANNON_PETS/agents`` is a manual copy/symlink (not automated).
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Mapping, Optional

ENV_UNIFIED = "SHANNON_PETS"
ENV_PACKAGES = "SHANNON_CODEX_PETS"
ENV_AGENTS = "SHANNON_PETS_AGENTS"
ENV_CODEX_HOME = "CODEX_HOME"
ENV_SHANNON_HOME = "SHANNON_LOG_DIR"
ENV_FLEXAID_HOME = "FLEXAIDDS_LOG_DIR"

AGENTS_SUBDIR = "agents"
PACKAGES_SUBDIR = "packages"


def _env(mapping: Optional[Mapping[str, str]] = None) -> Mapping[str, str]:
    return mapping if mapping is not None else os.environ


def _nonempty(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    t = value.strip()
    return t or None


def shannon_home(
    *,
    home: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
) -> Path:
    e = _env(env)
    if raw := _nonempty(e.get(ENV_SHANNON_HOME)):
        return Path(raw).expanduser()
    if raw := _nonempty(e.get(ENV_FLEXAID_HOME)):
        return Path(raw).expanduser()
    base = home if home is not None else Path.home()
    return base / ".shannon"


def unified_home(env: Optional[Mapping[str, str]] = None) -> Optional[Path]:
    raw = _nonempty(_env(env).get(ENV_UNIFIED))
    return Path(raw).expanduser() if raw else None


def package_roots(
    *,
    home: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
    include_repo_mirrors: bool = True,
) -> list[Path]:
    """Package search roots (first hit wins at resolve time)."""
    e = _env(env)
    base = home if home is not None else Path.home()
    roots: list[Path] = []
    seen: set[Path] = set()

    def append(p: Path) -> None:
        key = p.expanduser().resolve() if p.exists() else p.expanduser()
        # Dedup by string form when path does not exist yet.
        try:
            key = p.expanduser().resolve()
        except OSError:
            key = p.expanduser()
        if key in seen:
            return
        seen.add(key)
        roots.append(p.expanduser())

    if raw := _nonempty(e.get(ENV_PACKAGES)):
        append(Path(raw))

    if unified := unified_home(env=e):
        packages_only = unified / PACKAGES_SUBDIR
        if packages_only.is_dir():
            append(packages_only)
        append(unified)

    if raw := _nonempty(e.get(ENV_CODEX_HOME)):
        append(Path(raw) / "pets")

    append(base / ".codex" / "pets")

    if include_repo_mirrors:
        here = Path(__file__).resolve().parent
        append(here)  # hub/<id> mirrors
        append(here.parent / "pets")

    return roots


def agent_memory_root(
    *,
    home: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
) -> Path:
    e = _env(env)
    if raw := _nonempty(e.get(ENV_AGENTS)):
        return Path(raw).expanduser()
    if unified := unified_home(env=e):
        return unified / AGENTS_SUBDIR
    return shannon_home(home=home, env=e) / "pets"


def is_agent_memory_root(
    path: Path,
    *,
    home: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
) -> bool:
    try:
        return path.expanduser().resolve() == agent_memory_root(home=home, env=env).resolve()
    except OSError:
        return path.expanduser() == agent_memory_root(home=home, env=env)


def package_roots_excluding_memory(
    *,
    home: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
    include_repo_mirrors: bool = True,
) -> list[Path]:
    memory = agent_memory_root(home=home, env=env)
    try:
        mem_key = memory.resolve()
    except OSError:
        mem_key = memory
    out: list[Path] = []
    for root in package_roots(
        home=home, env=env, include_repo_mirrors=include_repo_mirrors
    ):
        try:
            key = root.resolve()
        except OSError:
            key = root
        if key != mem_key:
            out.append(root)
    return out


def snapshot(
    *,
    home: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
) -> dict[str, str]:
    e = _env(env)
    unified = unified_home(env=e)
    packages = package_roots(home=home, env=e)
    return {
        "unified": str(unified) if unified else "",
        "packages": ":".join(str(p) for p in packages),
        "agents": str(agent_memory_root(home=home, env=e)),
        "shannonHome": str(shannon_home(home=home, env=e)),
    }
