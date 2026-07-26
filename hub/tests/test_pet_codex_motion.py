"""Tests for pure signal → Codex motion mapping (shipped pet_codex_motion)."""

from __future__ import annotations

import json
from pathlib import Path

import pet_codex_motion as pcm

# Shared with Pill PetCodexMotionTests — fail closed if missing or labels drift.
_GOLDEN_PATH = Path(__file__).resolve().parent / "fixtures" / "pet_codex_motion_matrix.json"


def _load_golden_cases() -> list[dict]:
    if not _GOLDEN_PATH.is_file():
        raise FileNotFoundError(
            f"pet codex motion golden missing (fail closed): {_GOLDEN_PATH}"
        )
    data = json.loads(_GOLDEN_PATH.read_text(encoding="utf-8"))
    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        raise ValueError(f"golden has no cases: {_GOLDEN_PATH}")
    return cases


def _signals_from_case(raw: dict) -> pcm.PetMotionSignals:
    return pcm.PetMotionSignals(
        presence=str(raw.get("presence") or "observed"),
        status=str(raw.get("status") or "idle"),
        has_pending_ask=bool(raw.get("has_pending_ask", False)),
        last_outcome=raw.get("last_outcome"),
        just_approved=bool(raw.get("just_approved", False)),
        entropy_collapse=bool(raw.get("entropy_collapse", False)),
        celebrate_as_jump=bool(raw.get("celebrate_as_jump", False)),
    )


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

class TestMotionMatrixGolden:
    """T2 — shared Swift ↔ Python matrix; both sides must match expected labels."""

    def test_golden_file_exists(self):
        assert _GOLDEN_PATH.is_file(), f"missing golden (fail closed): {_GOLDEN_PATH}"

    def test_matrix_matches_map_pet_motion(self):
        cases = _load_golden_cases()
        mismatches: list[str] = []
        for case in cases:
            case_id = case.get("id", "<missing-id>")
            signals = _signals_from_case(case["signals"])
            got = pcm.map_pet_motion(signals)
            expected = case["expected"]
            if got != expected:
                mismatches.append(f"{case_id}: got {got!r} expected {expected!r}")
        assert not mismatches, (
            "Python map_pet_motion drifted from golden matrix:\n"
            + "\n".join(mismatches)
        )

