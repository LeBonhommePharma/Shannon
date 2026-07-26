#!/usr/bin/env python3
"""
pet_codex_motion.py — pure signal → Codex-aligned pet motion vocabulary.

Maps live agent/hub evidence onto the standard Codex v2 animation rows:

  idle | running | waiting | failed | review | waving | jumping

(running-right / running-left are locomotion polish; default busy work uses
``running`` row 7.)

This layer is intentionally separate from:
  * pet_manager.derive_mood  — coarse disk-honesty labels for ~/.shannon/pets
  * CompanionMood / PetAnimationState — procedural Canvas mood enums

Honesty rule (same as CompanionMood): observation-only presence may never
claim work. Busy motions require live-capable presence.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

# Codex-aligned motion labels (standard atlas rows 0–8 subset + polish).
MOTION_IDLE = "idle"
MOTION_RUNNING = "running"  # busy work (row 7), not foot-running
MOTION_WAITING = "waiting"
MOTION_FAILED = "failed"
MOTION_REVIEW = "review"
MOTION_WAVING = "waving"  # approval / greeting one-shot
MOTION_JUMPING = "jumping"  # optional celebration polish

# Required vocabulary for Shannon companion responsiveness.
CORE_MOTIONS = frozenset({
    MOTION_IDLE,
    MOTION_RUNNING,
    MOTION_WAITING,
    MOTION_FAILED,
    MOTION_REVIEW,
})

ALL_MOTIONS = frozenset({
    MOTION_IDLE,
    MOTION_RUNNING,
    MOTION_WAITING,
    MOTION_FAILED,
    MOTION_REVIEW,
    MOTION_WAVING,
    MOTION_JUMPING,
    "running-right",
    "running-left",
})

#: Presence values that may drive busy/work motions.
LIVE_PRESENCE = frozenset({"live", "connected", "online"})

#: Status values that mean mid-work (busy), when presence is live.
BUSY_STATUS = frozenset({"active", "mid_task", "mid-task", "running", "working"})

#: Status / flags meaning the agent needs the user (approval, blocked).
WAITING_STATUS = frozenset({
    "blocked", "waiting", "awaiting", "needs_user", "needs-user", "ask",
})

#: Explicit failure outcomes / statuses.
FAILED_OUTCOMES = frozenset({
    "failed", "fail", "error", "errored", "failure", "crash", "crashed",
})

#: Outcomes that map to the review row (inspect completed work).
REVIEW_OUTCOMES = frozenset({
    "review", "done", "success", "succeeded", "completed", "complete", "passed",
})

SLEEPY_AFTER: float = 300.0


@dataclass(frozen=True)
class PetMotionSignals:
    """Evidence tuple for deterministic motion selection.

    Fields mirror gate/card signals without depending on Swift types.
    """

    presence: str = "observed"
    status: str = "idle"
    #: Human ask pending (gate approval queue).
    has_pending_ask: bool = False
    #: Last turn/task outcome: success|failed|review|None.
    last_outcome: Optional[str] = None
    #: Approval celebration window (one-shot, maps to waving).
    just_approved: bool = False
    #: Live entropy collapse (Shannon δ) — surfaces as failed posture.
    entropy_collapse: bool = False
    seconds_since_seen: float = 0.0
    #: Prefer jumping over waving for celebrations when True.
    celebrate_as_jump: bool = False


def _norm(value: Optional[str]) -> str:
    return (value or "").strip().lower().replace(" ", "_")


def is_live_presence(presence: str) -> bool:
    return _norm(presence) in LIVE_PRESENCE


def map_pet_motion(signals: PetMotionSignals) -> str:
    """Map agent/hub signals to a Codex motion label.

    Deterministic pure function. Precedence (top wins):

      1. entropy_collapse + live → failed
      2. just_approved → waving (or jumping)
      3. live + (pending ask | waiting status) → waiting
      4. live + failed outcome → failed
      5. live + busy status → running
      6. live + review/success outcome (not busy) → review
      7. offline / very stale → idle (no sleepy row in Codex atlas)
      8. else idle
    """
    presence = _norm(signals.presence)
    status = _norm(signals.status)
    outcome = _norm(signals.last_outcome) if signals.last_outcome else ""
    live = is_live_presence(presence)

    # 1. Collapse outranks celebration — same honesty as CompanionMood.wary.
    if live and signals.entropy_collapse:
        return MOTION_FAILED

    # 2. Approval one-shot.
    if signals.just_approved:
        return MOTION_JUMPING if signals.celebrate_as_jump else MOTION_WAVING

    # 3–6 only from live-capable presence (observation must not claim work).
    if live:
        if signals.has_pending_ask or status in WAITING_STATUS:
            return MOTION_WAITING
        if outcome in FAILED_OUTCOMES or status in FAILED_OUTCOMES:
            return MOTION_FAILED
        if status in BUSY_STATUS:
            return MOTION_RUNNING
        if outcome in REVIEW_OUTCOMES:
            return MOTION_REVIEW

    # Stale / offline / observed — Codex has no sleepy row; idle is honest.
    return MOTION_IDLE


def motion_claims_work(motion: str) -> bool:
    """True only for motions that assert the agent is doing work."""
    return _norm(motion) in {MOTION_RUNNING, "running-right", "running-left"}


def companion_mood_to_motion(
    mood: str,
    *,
    status: str = "idle",
    has_pending_ask: bool = False,
    last_outcome: Optional[str] = None,
) -> str:
    """Bridge from Shannon procedural mood labels to Codex motion rows.

    Used when a caller already has CompanionMood / pet_manager mood and wants
    an atlas row without re-deriving from raw signals.
    """
    m = _norm(mood)
    st = _norm(status)
    if m in {"wary", "uneasy"}:
        return MOTION_FAILED
    if m in {"happy", "celebrating"}:
        return MOTION_WAVING
    if m in {"alert", "focused", "grinding"}:
        if has_pending_ask or st in WAITING_STATUS:
            return MOTION_WAITING
        if last_outcome and _norm(last_outcome) in FAILED_OUTCOMES:
            return MOTION_FAILED
        return MOTION_RUNNING
    if m in {"review"}:
        return MOTION_REVIEW
    # idle / resting / sleeping / watching / unknown
    if last_outcome and _norm(last_outcome) in REVIEW_OUTCOMES:
        return MOTION_REVIEW
    return MOTION_IDLE
