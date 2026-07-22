import pytest

import pet_manager as pm


@pytest.fixture
def manager(tmp_path):
    return pm.PetManager(pets_dir=tmp_path / "pets", db_path=tmp_path / "agent_hub.db")


class TestPetStateIO:
    def test_ensure_pet_creates_expected_files(self, manager):
        agent_dir = manager.pets_dir / "science"
        assert (agent_dir / "memory.md").exists()
        assert (agent_dir / "history.jsonl").exists()
        assert (agent_dir / "config.json").exists()
        assert (agent_dir / "state.json").exists()

    def test_read_state_defaults(self, manager):
        state = manager.read_state("science")
        assert state.status == "idle"
        assert state.resumable is False

    def test_write_state_roundtrip(self, manager):
        state = manager.read_state("science")
        state.status = "active"
        state.last_task = "docking 1ACJ"
        manager.write_state("science", state)

        reloaded = manager.read_state("science")
        assert reloaded.status == "active"
        assert reloaded.last_task == "docking 1ACJ"
        assert reloaded.updated_at > 0

    def test_append_and_read_memory(self, manager):
        manager.append_memory("science", "CF=-3.217 for target 1ACJ")
        text = manager.read_memory("science")
        assert "CF=-3.217" in text

    def test_read_memory_truncated(self, manager):
        manager.append_memory("science", "x" * 100)
        text = manager.read_memory("science", max_bytes=10)
        assert len(text) == 10

    def test_append_and_recent_history(self, manager):
        for i in range(5):
            manager.append_history("science", {"event": "turn", "i": i})
        history = manager.recent_history("science", n=3)
        assert len(history) == 3
        assert history[-1]["i"] == 4


class TestDivergenceCheck:
    def test_no_memory_returns_none(self, manager):
        assert manager.check_divergence("science", -3.2) is None

    def test_within_threshold_returns_none(self, manager):
        manager.append_memory("science", "Result: CF=-3.2 for 1ACJ")
        result = manager.check_divergence("science", -3.5, threshold=20.0)
        assert result is None

    def test_exceeds_threshold_returns_warning(self, manager):
        manager.append_memory("science", "Result: CF=-3.2 for 1ACJ")
        result = manager.check_divergence("science", -50.0, threshold=20.0)
        assert result is not None
        assert "divergence" in result
        assert "science" in result

    def test_handles_unicode_minus_sign(self, manager):
        manager.append_memory("science", "Result: CF−187.3 kcal/mol")
        result = manager.check_divergence("science", -187.5, threshold=1.0)
        assert result is None  # delta of 0.2 well within threshold

    def test_no_cf_pattern_returns_none(self, manager):
        manager.append_memory("science", "No numeric data here at all")
        assert manager.check_divergence("science", -3.2) is None


class TestTurnHelpers:
    def test_on_agent_turn_start_and_end(self, manager, monkeypatch):
        monkeypatch.setattr(pm, "_default_manager", manager)

        pm.on_agent_turn_start("science", "benchmark run")
        state = manager.read_state("science")
        assert state.status == "active"
        assert state.resumable is True

        pm.on_agent_turn_end("science", "completed", cf=-3.2, entropy=1.8)
        state = manager.read_state("science")
        assert state.status == "idle"
        assert state.resumable is False
        assert state.last_cf_delta == pytest.approx(-3.2)
