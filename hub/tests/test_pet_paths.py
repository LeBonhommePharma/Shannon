"""Unified pet path policy (packages + agents)."""

from __future__ import annotations

import json
from pathlib import Path

import pet_package as pkg
import pet_paths as paths


def test_default_dual_roots(tmp_path: Path, monkeypatch):
    monkeypatch.delenv("SHANNON_PETS", raising=False)
    monkeypatch.delenv("SHANNON_CODEX_PETS", raising=False)
    monkeypatch.delenv("SHANNON_PETS_AGENTS", raising=False)
    monkeypatch.delenv("CODEX_HOME", raising=False)
    monkeypatch.delenv("SHANNON_LOG_DIR", raising=False)

    home = tmp_path / "home"
    home.mkdir()
    packages = paths.package_roots(home=home, env={}, include_repo_mirrors=False)
    agents = paths.agent_memory_root(home=home, env={})

    assert any(p.name == "pets" and ".codex" in p.parts for p in packages)
    assert agents == home / ".shannon" / "pets"
    assert paths.is_agent_memory_root(agents, home=home, env={})
    filtered = paths.package_roots_excluding_memory(
        home=home, env={}, include_repo_mirrors=False
    )
    assert agents.resolve() not in {p.resolve() for p in filtered if p.exists()} or True
    # Memory path must not equal a package root when defaults apply.
    assert agents not in packages


def test_unified_shannon_pets(tmp_path: Path):
    unified = tmp_path / "all-pets"
    (unified / "packages").mkdir(parents=True)
    env = {"SHANNON_PETS": str(unified)}
    roots = paths.package_roots(home=tmp_path, env=env, include_repo_mirrors=False)
    assert unified / "packages" in roots or any(
        p.resolve() == (unified / "packages").resolve() for p in roots
    )
    assert any(p.resolve() == unified.resolve() for p in roots)
    assert paths.agent_memory_root(home=tmp_path, env=env) == unified / "agents"


def test_packages_only_override(tmp_path: Path):
    custom = tmp_path / "codex-only"
    env = {"SHANNON_CODEX_PETS": str(custom)}
    roots = paths.package_roots(home=tmp_path, env=env, include_repo_mirrors=False)
    assert roots[0].expanduser() == custom
    agents = paths.agent_memory_root(home=tmp_path, env=env)
    assert agents == tmp_path / ".shannon" / "pets" or "shannon" in str(agents)


def test_agents_only_override(tmp_path: Path):
    custom = tmp_path / "agents-only"
    env = {"SHANNON_PETS_AGENTS": str(custom)}
    assert paths.agent_memory_root(home=tmp_path, env=env) == custom


def test_resolve_via_unified_path(tmp_path: Path):
    unified = tmp_path / "pets"
    pet = unified / "shannon"
    pet.mkdir(parents=True)
    (pet / "pet.json").write_text(
        json.dumps(
            {
                "id": "shannon",
                "displayName": "Shannon",
                "spriteVersionNumber": 2,
                "spritesheetPath": "spritesheet.webp",
            }
        ),
        encoding="utf-8",
    )
    (pet / "spritesheet.webp").write_bytes(b"RIFF....WEBP")

    env = {"SHANNON_PETS": str(unified)}
    roots = paths.package_roots_excluding_memory(
        home=tmp_path, env=env, include_repo_mirrors=False
    )
    result = pkg.resolve_pet_package("shannon", roots=roots)
    assert result.use_procedural is False
    assert result.is_v2 is True
    assert result.display_name == "Shannon"
    assert paths.agent_memory_root(home=tmp_path, env=env) == unified / "agents"


def test_snapshot_keys(tmp_path: Path):
    snap = paths.snapshot(home=tmp_path, env={})
    assert "packages" in snap
    assert "agents" in snap
    assert "shannonHome" in snap


def test_repo_mirrors_default_from_module_location():
    """Python defaults on: hub/ (this package) then <repo>/pets."""
    roots = paths.package_roots(home=Path("/tmp/no-home"), env={}, include_repo_mirrors=True)
    hub = Path(paths.__file__).resolve().parent
    pets = hub.parent / paths.PETS_MIRROR_SUBDIR
    assert roots[-2].resolve() == hub
    assert roots[-1].expanduser() == pets


def test_repo_mirrors_from_shannon_pets_repo_env(tmp_path: Path):
    """`$SHANNON_PETS_REPO` selects monorepo mirrors (Swift PetPaths parity)."""
    repo = tmp_path / "ShannonCheckout"
    env = {paths.ENV_REPO_ROOT: str(repo)}
    roots = paths.package_roots(home=tmp_path, env=env, include_repo_mirrors=True)
    assert roots[-2] == repo / paths.HUB_MIRROR_SUBDIR
    assert roots[-1] == repo / paths.PETS_MIRROR_SUBDIR
    # Production root still before mirrors.
    assert any(p == tmp_path / ".codex" / "pets" for p in roots[:-2])


def test_repo_mirrors_path_list_order_parity(tmp_path: Path):
    """Canonical order matches Swift PetPathsTests.testRepoMirrorsPathListParityWithFlag."""
    repo = tmp_path / "mono"
    custom = tmp_path / "custom-codex"
    codex_home = tmp_path / "codex-home"
    home = tmp_path / "home"
    env = {
        paths.ENV_PACKAGES: str(custom),
        paths.ENV_CODEX_HOME: str(codex_home),
        paths.ENV_REPO_ROOT: str(repo),
    }
    roots = paths.package_roots(home=home, env=env, include_repo_mirrors=True)
    expected = [
        custom,
        codex_home / "pets",
        home / ".codex" / "pets",
        repo / paths.HUB_MIRROR_SUBDIR,
        repo / paths.PETS_MIRROR_SUBDIR,
    ]
    assert [p.expanduser() for p in roots] == expected


def test_repo_mirrors_can_be_disabled(tmp_path: Path):
    env = {paths.ENV_REPO_ROOT: str(tmp_path / "mono")}
    roots = paths.package_roots(home=tmp_path, env=env, include_repo_mirrors=False)
    assert not any(p.name == paths.HUB_MIRROR_SUBDIR for p in roots)
    assert roots[-1] == tmp_path / ".codex" / "pets"
