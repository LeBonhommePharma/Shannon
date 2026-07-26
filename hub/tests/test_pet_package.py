"""Tests for Codex v2 pet package discovery + procedural fallback."""

from __future__ import annotations

import json
from pathlib import Path

import pet_package as pkg


def _write_package(root: Path, pet_id: str = "fixture-pet", version: int = 2) -> Path:
    d = root / pet_id
    d.mkdir(parents=True, exist_ok=True)
    sheet = d / "spritesheet.webp"
    sheet.write_bytes(b"RIFF....WEBP")  # placeholder bytes; resolve only checks is_file
    meta = {
        "id": pet_id,
        "displayName": "Fixture Pet",
        "description": "test package",
        "spriteVersionNumber": version,
        "spritesheetPath": "spritesheet.webp",
    }
    (d / "pet.json").write_text(json.dumps(meta), encoding="utf-8")
    return d


class TestResolveFound:
    def test_resolves_v2_package(self, tmp_path: Path):
        _write_package(tmp_path, "fixture-pet", version=2)
        result = pkg.resolve_pet_package("fixture-pet", roots=[tmp_path])
        assert result.use_procedural is False
        assert result.is_v2 is True
        assert result.sprite_version == 2
        assert result.pet_id == "fixture-pet"
        assert result.spritesheet_path.is_file()
        assert result.pet_json_path.is_file()
        assert result.display_name == "Fixture Pet"
        d = result.to_dict()
        assert d["is_v2"] is True
        assert d["use_procedural"] is False

    def test_resolve_consistent_twice(self, tmp_path: Path):
        _write_package(tmp_path, "stable-pet")
        a = pkg.resolve_pet_package("stable-pet", roots=[tmp_path])
        b = pkg.resolve_pet_package("stable-pet", roots=[tmp_path])
        assert a.use_procedural is False
        assert b.use_procedural is False
        assert a.spritesheet_path == b.spritesheet_path
        assert a.sprite_version == b.sprite_version == 2


class TestResolveMissing:
    def test_missing_package_uses_procedural(self, tmp_path: Path):
        result = pkg.resolve_pet_package("does-not-exist", roots=[tmp_path])
        assert result.use_procedural is True
        assert result.is_v2 is False
        assert result.sprite_version == 0
        assert "procedural" in " ".join(result.notes).lower()

    def test_missing_twice_consistent(self, tmp_path: Path):
        a = pkg.resolve_pet_package("nope", roots=[tmp_path])
        b = pkg.resolve_pet_package("nope", roots=[tmp_path])
        assert a.use_procedural and b.use_procedural

    def test_missing_sheet_not_a_package(self, tmp_path: Path):
        d = tmp_path / "half"
        d.mkdir()
        (d / "pet.json").write_text(
            json.dumps({"id": "half", "spriteVersionNumber": 2}),
            encoding="utf-8",
        )
        result = pkg.resolve_pet_package("half", roots=[tmp_path])
        assert result.use_procedural is True


class TestMemoryRootIsolated:
    def test_agent_memory_root_not_used_for_sprites(self, tmp_path: Path, monkeypatch):
        # Plant a fake "package" under the memory root — must NOT resolve as art.
        monkeypatch.setenv("SHANNON_LOG_DIR", str(tmp_path / "shannon"))
        mem = pkg.agent_memory_pets_root()
        _write_package(mem, "agent-lookalike")
        # Search only memory-ish path via roots that include memory
        result = pkg.resolve_pet_package(
            "agent-lookalike",
            roots=[mem],  # resolve filters memory root out
        )
        assert result.use_procedural is True

    def test_memory_path_contract_files(self, tmp_path: Path, monkeypatch):
        monkeypatch.setenv("SHANNON_LOG_DIR", str(tmp_path / "shannon"))
        import pet_manager as pm

        mgr = pm.PetManager(
            pets_dir=tmp_path / "shannon" / "pets",
            db_path=tmp_path / "shannon" / "agent_hub.db",
        )
        d = mgr.pets_dir / "science"
        assert (d / "state.json").exists()
        assert (d / "memory.md").exists()
        assert (d / "history.jsonl").exists()
        # No pet.json / spritesheet in memory dir
        assert not (d / "pet.json").exists()
        assert not (d / "spritesheet.webp").exists()


class TestListPackages:
    def test_list_finds_v2(self, tmp_path: Path):
        _write_package(tmp_path, "a")
        _write_package(tmp_path, "b")
        found = pkg.list_pet_packages(roots=[tmp_path], require_v2=True)
        ids = {p.pet_id for p in found}
        assert "a" in ids and "b" in ids
