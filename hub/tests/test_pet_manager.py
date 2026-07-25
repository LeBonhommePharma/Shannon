import json
import time

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


class TestMood:
    """Coarse mood derivation. The honesty tests at the bottom are the point."""

    def test_idle_recently_seen_is_resting(self, manager):
        state = manager.read_state("science")
        state.updated_at = 1000.0
        assert pm.derive_mood(state, [], now=1010.0) == "resting"

    def test_idle_stale_is_sleeping(self, manager):
        state = manager.read_state("science")
        state.updated_at = 1000.0
        far = 1000.0 + pm.MOOD_SLEEP_AFTER + 10
        assert pm.derive_mood(state, [], now=far) == "sleeping"

    def test_never_touched_pet_is_resting_not_sleeping(self, manager):
        # A freshly-created pet has updated_at == 0.0; it must not read as
        # having slept since the epoch.
        state = manager.read_state("science")
        assert state.updated_at == 0.0
        assert pm.derive_mood(state, [], now=1_000_000.0) == "resting"

    def test_active_is_focused(self, manager):
        state = manager.read_state("science")
        state.status = "active"
        state.updated_at = 1000.0
        assert pm.derive_mood(state, [], now=1005.0) == "focused"

    def test_mid_task_is_grinding(self, manager):
        state = manager.read_state("science")
        state.status = "mid_task"
        state.updated_at = 1000.0
        assert pm.derive_mood(state, [], now=1005.0) == "grinding"

    def test_recent_success_is_celebrating(self, manager):
        state = manager.read_state("science")
        recent = [{"event": "turn_end", "outcome": "completed", "ts": 1000.0}]
        assert pm.derive_mood(state, recent, now=1005.0) == "celebrating"

    def test_stale_success_is_not_celebrating(self, manager):
        state = manager.read_state("science")
        state.updated_at = 1000.0
        recent = [{"event": "turn_end", "outcome": "completed", "ts": 1000.0}]
        far = 1000.0 + pm.CELEBRATE_WINDOW + 30
        assert pm.derive_mood(state, recent, now=far) == "resting"

    def test_failed_outcome_does_not_celebrate(self, manager):
        state = manager.read_state("science")
        state.updated_at = 1000.0
        recent = [{"event": "turn_end", "outcome": "failed: clash", "ts": 1000.0}]
        assert pm.derive_mood(state, recent, now=1005.0) == "resting"

    def test_celebrating_outranks_active_status(self, manager):
        state = manager.read_state("science")
        state.status = "active"
        state.updated_at = 1000.0
        recent = [{"event": "turn_end", "outcome": "success", "ts": 1000.0}]
        assert pm.derive_mood(state, recent, now=1002.0) == "celebrating"

    def test_manager_mood_end_to_end(self, manager):
        state = manager.read_state("science")
        state.status = "mid_task"
        manager.write_state("science", state)
        assert manager.mood("science") == "grinding"


class TestMoodHonesty:
    """No pet record may launder a ⌘D observation into a claim of work.

    `~/.shannon/pets/*/state.json` is written from whichever macOS app was
    frontmost. The gate (agent_hub.db) is the only authority on liveness.
    """

    def test_observed_record_never_claims_work(self, manager):
        state = manager.read_state("science")
        state.source = "observed"
        state.updated_at = 1000.0
        for status in ("active", "mid_task", "idle", "observed"):
            state.status = status
            mood = pm.derive_mood(state, [], now=1005.0)
            assert mood not in pm.MOOD_CLAIMS_WORK, f"{status} -> {mood}"
            assert mood == "watching"

    def test_observed_status_alone_is_enough_to_mark_an_observation(self, manager):
        # Records written by AgentIngest.PetBootstrap set both fields; older
        # ones may set only `status`.
        state = manager.read_state("science")
        state.status = "observed"
        state.updated_at = 1000.0
        assert pm.derive_mood(state, [], now=1005.0) == "watching"

    def test_stale_observation_sleeps(self, manager):
        state = manager.read_state("science")
        state.source, state.status = "observed", "observed"
        state.updated_at = 1000.0
        far = 1000.0 + pm.MOOD_SLEEP_AFTER + 1
        assert pm.derive_mood(state, [], now=far) == "sleeping"

    def test_legacy_stale_active_record_does_not_claim_work(self, manager):
        # The exact shape sitting in ~/.shannon/pets today: ⌘D wrote
        # "status": "active" two days ago and nothing ever cleared it.
        state = manager.read_state("science")
        state.status = "active"          # no `source` — predates the fix
        state.updated_at = 1000.0
        mood = pm.derive_mood(state, [], now=1000.0 + 2 * 86_400)
        assert mood == "sleeping"
        assert mood not in pm.MOOD_CLAIMS_WORK

    def test_active_claim_expires_after_the_live_window(self, manager):
        state = manager.read_state("science")
        state.status = "active"
        state.updated_at = 1000.0
        assert pm.derive_mood(state, [], now=1000.0 + pm.LIVE_WINDOW - 1) == "focused"
        assert pm.derive_mood(state, [], now=1000.0 + pm.LIVE_WINDOW + 1) == "resting"

    def test_no_input_makes_an_observation_focused(self, manager):
        """Exhaustive: nothing an observation can carry may claim work."""
        for status in ("active", "mid_task", "idle", "blocked", "observed", ""):
            for age in (0.0, 10.0, 89.0, 200.0, 100_000.0):
                for recent in ([], [{"event": "turn_end", "outcome": "failed",
                                     "ts": 1000.0}]):
                    state = pm.PetState(status=status, source="observed",
                                        updated_at=1000.0)
                    mood = pm.derive_mood(state, recent, now=1000.0 + age)
                    assert mood not in pm.MOOD_CLAIMS_WORK, (status, age, mood)

    def test_only_two_moods_claim_work(self):
        assert pm.MOOD_CLAIMS_WORK == {"focused", "grinding"}


class TestObservationLifecycle:
    """An observation is a snapshot, not a permanent brand on the record.

    ⌘D writes `status/source = "observed"` once. Real agent telemetry landing
    on the same record afterwards must supersede that provenance, otherwise
    every agent whose pet was ever captured is stuck on `watching` forever.
    """

    def _capture_via_cmd_d(self, manager, agent_id="science", task=""):
        """Reproduce exactly what AgentIngest.PetBootstrap writes to state.json."""
        path = manager.pets_dir / agent_id / "state.json"
        path.write_text(json.dumps({
            "status": "observed",
            "source": "observed",
            "last_task": task,
            "last_cf_delta": None,
            "memory_size": 0,
            "history_count": 0,
            "updated_at": time.time(),
            "resumable": bool(task),
        }))

    def test_cmd_d_capture_reads_as_watching(self, manager):
        self._capture_via_cmd_d(manager)
        assert manager.mood("science") == "watching"

    def test_turn_start_supersedes_a_previous_observation(self, manager, monkeypatch):
        monkeypatch.setattr(pm, "_default_manager", manager)
        self._capture_via_cmd_d(manager, task="Xcode")
        assert manager.mood("science") == "watching"

        pm.on_agent_turn_start("science", "benchmark run")

        state = manager.read_state("science")
        assert state.status == "active"
        assert state.is_observation is False, "telemetry must clear the ⌘D marker"
        assert manager.mood("science") == "focused"

    def test_turn_end_supersedes_a_previous_observation(self, manager, monkeypatch):
        monkeypatch.setattr(pm, "_default_manager", manager)
        self._capture_via_cmd_d(manager, task="Xcode")

        pm.on_agent_turn_end("science", "wrapped up", cf=-3.2)

        state = manager.read_state("science")
        assert state.is_observation is False
        assert manager.mood("science") == "resting"

    def test_mid_task_telemetry_after_an_observation_can_grind(self, manager, monkeypatch):
        monkeypatch.setattr(pm, "_default_manager", manager)
        self._capture_via_cmd_d(manager)

        state = manager.read_state("science")
        state.mark_agent_telemetry()
        state.status = "mid_task"
        manager.write_state("science", state)

        assert manager.mood("science") == "grinding"

    def test_observed_status_is_dropped_when_telemetry_supersedes(self, manager):
        """`status == "observed"` alone also marks an observation — clear it too."""
        state = pm.PetState(status="observed", source="observed", updated_at=1000.0)
        state.mark_agent_telemetry()
        assert state.is_observation is False
        assert state.status not in pm.OBSERVED_MARKERS
        assert state.source == pm.SOURCE_AGENT


class TestUnknownTimestampHonesty:
    """`updated_at == 0.0` is unknown age, not "seen just now"."""

    def test_zero_timestamp_never_claims_work(self, manager):
        for status in ("active", "mid_task"):
            state = pm.PetState(status=status, updated_at=0.0)
            mood = pm.derive_mood(state, [], now=1_000_000.0)
            assert mood not in pm.MOOD_CLAIMS_WORK, (status, mood)
            assert mood == "resting"

    def test_state_json_missing_updated_at_never_claims_work(self, manager):
        path = manager.pets_dir / "science" / "state.json"
        path.write_text(json.dumps({"status": "active", "last_task": "who knows"}))
        state = manager.read_state("science")
        assert state.updated_at == 0.0
        assert manager.mood("science") == "resting"

    def test_negative_timestamp_never_claims_work(self, manager):
        state = pm.PetState(status="active", updated_at=-1.0)
        mood = pm.derive_mood(state, [], now=1_000_000.0)
        assert mood not in pm.MOOD_CLAIMS_WORK

    def test_unknown_age_still_reads_as_resting_not_sleeping(self, manager):
        state = pm.PetState(status="idle", updated_at=0.0)
        assert pm.derive_mood(state, [], now=1_000_000.0) == "resting"


class TestOutcomeMatching:
    """A failure phrasing that merely embeds a success word is still a failure."""

    @pytest.mark.parametrize("outcome", [
        "incomplete",
        "unsuccessful",
        "did not pass",
        "task incomplete",
        "run was unsuccessful",
        "tests did not pass",
        "not solved",
        "no records written",
        "never completed",
        "completion failed",
    ])
    def test_failure_phrasings_do_not_celebrate(self, manager, outcome):
        state = pm.PetState(updated_at=1000.0)
        recent = [{"event": "turn_end", "outcome": outcome, "ts": 1000.0}]
        assert pm.derive_mood(state, recent, now=1005.0) == "resting"

    @pytest.mark.parametrize("outcome", [
        "success",
        "completed",
        "COMPLETED",
        "all tests passed",
        "solved 1ACJ",
        "finished successfully",
        "new record CF=-187.3",
    ])
    def test_real_successes_still_celebrate(self, manager, outcome):
        state = pm.PetState(updated_at=1000.0)
        recent = [{"event": "turn_end", "outcome": outcome, "ts": 1000.0}]
        assert pm.derive_mood(state, recent, now=1005.0) == "celebrating"


class TestOutcomeNegationReach:
    """A negation binds to its whole clause, not to a fixed-width lookback.

    The token rewrite fixed "did not pass" with a 3-token window, but the
    negation and the success stem can sit arbitrarily far apart — "not a single
    test passed" is four tokens, and celebrated a failed run.
    """

    @pytest.mark.parametrize("outcome", [
        "not a single test passed",
        "no tests were able to pass",
        "none of the 40 targets solved",
        "did not successfully complete the record run",
        "0 tests passed",
        "un-successful",
        "in-complete",
    ])
    def test_distant_negation_still_blocks_celebration(self, manager, outcome):
        state = pm.PetState(updated_at=1000.0)
        recent = [{"event": "turn_end", "outcome": outcome, "ts": 1000.0}]
        assert pm.outcome_is_success(outcome) is False
        assert pm.derive_mood(state, recent, now=1005.0) == "resting"

    @pytest.mark.parametrize("outcome", [
        "all tests passed, 0 failures",
        "completed; 3 warnings, no errors",
        "no regressions, all targets solved",
    ])
    def test_negated_failure_counts_do_not_veto_a_real_win(self, manager, outcome):
        """A zeroed/negated failure word is not a failure — "0 failures" is a win.

        The blanket failure-token veto swallowed these, so a genuinely good
        turn stopped celebrating: a regression on the honest path.
        """
        state = pm.PetState(updated_at=1000.0)
        recent = [{"event": "turn_end", "outcome": outcome, "ts": 1000.0}]
        assert pm.outcome_is_success(outcome) is True
        assert pm.derive_mood(state, recent, now=1005.0) == "celebrating"


class TestFutureTimestampHonesty:
    """A timestamp from the future is not proof of freshness either."""

    def test_future_updated_at_never_claims_work(self, manager):
        now = 1_000_000.0
        for status in ("active", "mid_task"):
            state = pm.PetState(status=status, updated_at=now + 10 * 365 * 86_400)
            mood = pm.derive_mood(state, [], now=now)
            assert mood not in pm.MOOD_CLAIMS_WORK, (status, mood)
            assert mood == "resting"

    def test_state_json_dated_in_the_future_never_claims_work(self, manager):
        path = manager.pets_dir / "science" / "state.json"
        path.write_text(json.dumps({"status": "active", "source": "agent",
                                    "updated_at": time.time() + 86_400}))
        assert manager.mood("science") == "resting"

    def test_small_clock_skew_is_still_tolerated(self, manager):
        """Sub-grace jitter between writer and reader must not break liveness."""
        now = 1_000_000.0
        state = pm.PetState(status="active", updated_at=now + 1.0)
        assert pm.derive_mood(state, [], now=now) == "focused"

    def test_future_dated_turn_end_does_not_celebrate(self, manager):
        now = 1_000_000.0
        state = pm.PetState(updated_at=now)
        recent = [{"event": "turn_end", "outcome": "completed",
                   "ts": now + 10 * 365 * 86_400}]
        assert pm.derive_mood(state, recent, now=now) == "resting"


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
