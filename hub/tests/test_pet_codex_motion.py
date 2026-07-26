"""Tests for pure signal → Codex motion mapping (shipped pet_codex_motion)."""

from __future__ import annotations

import pet_codex_motion as pcm


class TestCoreVocabulary:
    def test_core_motions_present(self):
        for name in ("idle", "running", "waiting", "failed", "review"):
            assert name in pcm.CORE_MOTIONS

    def test_idle_default(self):
        assert pcm.map_pet_motion(pcm.PetMotionSignals()) == "idle"

    def test_live_busy_is_running(self):
        m = pcm.map_pet_motion(
            pcm.PetMotionSignals(presence="live", status="active")
        )
        assert m == "running"
        assert pcm.motion_claims_work(m)

    def test_live_mid_task_is_running(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(presence="live", status="mid_task")
            )
            == "running"
        )

    def test_live_waiting_status(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(presence="live", status="blocked")
            )
            == "waiting"
        )

    def test_pending_ask_is_waiting(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(
                    presence="live", status="active", has_pending_ask=True
                )
            )
            == "waiting"
        )

    def test_failed_outcome(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(
                    presence="live", status="idle", last_outcome="failed"
                )
            )
            == "failed"
        )

    def test_review_after_success(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(
                    presence="live", status="idle", last_outcome="success"
                )
            )
            == "review"
        )

    def test_just_approved_is_waving(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(presence="live", just_approved=True)
            )
            == "waving"
        )

    def test_just_approved_jump_option(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(
                    presence="live", just_approved=True, celebrate_as_jump=True
                )
            )
            == "jumping"
        )

    def test_entropy_collapse_is_failed_and_outranks_approval(self):
        m = pcm.map_pet_motion(
            pcm.PetMotionSignals(
                presence="live",
                status="active",
                just_approved=True,
                entropy_collapse=True,
            )
        )
        assert m == "failed"

    def test_observed_busy_never_claims_work(self):
        m = pcm.map_pet_motion(
            pcm.PetMotionSignals(presence="observed", status="active")
        )
        assert m == "idle"
        assert not pcm.motion_claims_work(m)

    def test_offline_is_idle(self):
        assert (
            pcm.map_pet_motion(
                pcm.PetMotionSignals(presence="offline", status="mid_task")
            )
            == "idle"
        )


class TestResponsiveness:
    """Flip one input → motion label changes (acceptance criterion 2)."""

    def test_flip_status_active_to_blocked(self):
        base = pcm.PetMotionSignals(presence="live", status="active")
        assert pcm.map_pet_motion(base) == "running"
        flipped = pcm.PetMotionSignals(presence="live", status="blocked")
        assert pcm.map_pet_motion(flipped) == "waiting"
        assert pcm.map_pet_motion(base) != pcm.map_pet_motion(flipped)

    def test_flip_outcome_to_failed(self):
        ok = pcm.PetMotionSignals(
            presence="live", status="idle", last_outcome="success"
        )
        bad = pcm.PetMotionSignals(
            presence="live", status="idle", last_outcome="failed"
        )
        assert pcm.map_pet_motion(ok) == "review"
        assert pcm.map_pet_motion(bad) == "failed"

    def test_flip_presence_drops_running(self):
        live = pcm.PetMotionSignals(presence="live", status="active")
        obs = pcm.PetMotionSignals(presence="observed", status="active")
        assert pcm.map_pet_motion(live) == "running"
        assert pcm.map_pet_motion(obs) == "idle"


class TestMoodBridge:
    def test_alert_to_running(self):
        assert pcm.companion_mood_to_motion("alert") == "running"

    def test_wary_to_failed(self):
        assert pcm.companion_mood_to_motion("wary") == "failed"

    def test_happy_to_waving(self):
        assert pcm.companion_mood_to_motion("happy") == "waving"

    def test_idle_to_idle(self):
        assert pcm.companion_mood_to_motion("resting") == "idle"
