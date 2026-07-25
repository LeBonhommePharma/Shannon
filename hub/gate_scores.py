"""Extracted pure gate score helpers (P2.1 modularization)."""

from __future__ import annotations

import math
from typing import Any, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from shannon_gate import GateDecision, AgentMessage


def registry_entropy_score(decision: "GateDecision") -> float:
    """The ONLY number that may be written to ``agents.entropy_score``.

    Always ``decision.computed_H`` — message content entropy, not token H.
    """
    h = float(decision.computed_H)
    if not math.isfinite(h):
        return 0.0
    return h


def is_human_approval_request(msg: "AgentMessage") -> bool:
    """True when this message is an agent asking a human for yes/no."""
    if msg.message_type == "approval_needed":
        return True
    payload = msg.payload or {}
    return bool(payload.get("approval_needed") or payload.get("require_approval"))
