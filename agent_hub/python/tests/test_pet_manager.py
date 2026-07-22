"""Tests for pet_manager.py — uses tmp_path, never touches the real ~/.shannon dir."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pet_manager import PetManager, PetState  # noqa: E402


def make_manager(tmp_path):
    return PetManager(pets_dir=tmp_path / "pets", db_path=tmp_path / "hub.db")


class TestBootstrap:
    def test_ensure_pet_creates_files(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("dataset_runner")
        d = tmp_path / "pets" / "dataset_runner"
        assert (d / "memory.md").exists()
        assert (d / "history.jsonl").exists()
        assert (d / "config.json").exists()
        assert (d / "state.json").exists()


class TestState:
    def test_write_and_read_state(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("science")
        state = PetState(status="active", last_task="benchmark_v1")
        mgr.write_state("science", state)
        loaded = mgr.read_state("science")
        assert loaded.status == "active"
        assert loaded.last_task == "benchmark_v1"

    def test_read_state_missing_file_returns_default(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("science")
        loaded = mgr.read_state("science")
        assert loaded.status == "idle"


class TestMemory:
    def test_append_and_read_memory(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("codex")
        mgr.append_memory("codex", "Found CF -180.2 on target 1SG0")
        text = mgr.read_memory("codex")
        assert "CF -180.2" in text

    def test_read_memory_truncated(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("codex")
        mgr.append_memory("codex", "x" * 100)
        text = mgr.read_memory("codex", max_bytes=10)
        assert len(text) == 10


class TestHistory:
    def test_append_and_recent_history(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("grok_build")
        mgr.append_history("grok_build", {"decision": "pass", "H": 1.2})
        mgr.append_history("grok_build", {"decision": "flag", "H": 3.9})
        recent = mgr.recent_history("grok_build", n=1)
        assert len(recent) == 1
        assert recent[0]["decision"] == "flag"

    def test_recent_history_empty_when_missing(self, tmp_path):
        mgr = make_manager(tmp_path)
        mgr.ensure_pet("grok_build")
        assert mgr.recent_history("grok_build") == []
