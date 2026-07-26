"""Extracted pure gate score helpers (P2.1 modularization)."""

from __future__ import annotations

import math
import re
from typing import Any, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from shannon_gate import GateDecision, AgentMessage

# Message types that refresh agents.entropy_score (live HUD H).
# Heartbeat / process-attach status spam is excluded so the pill does not
# freeze on a single short-status H (e.g. always "Working in Ghostty" → ~2.38).
#
# That ~2.38 figure is NOT token-distribution collapse from the Shannon
# library (logits/logprobs, ~8–12 → ~2–4). It is a *systematic attach-spam
# signature*: identical short ⌘D / process-attach status text always scores
# the same message-content H. Seeing it a lot means attach traffic (or an
# old unstamped score) is dominating — not that the model is collapsed.
_REGISTRY_ENTROPY_TYPES = frozenset({
    "result",
    "code_suggestion",
    "benchmark_update",
    "alert",
    "approval_needed",
})

# ⌘D default task template: "Working in Ghostty" / "Working in Cursor" …
_WORKING_IN_RE = re.compile(r"^working in\s+\S", re.IGNORECASE)

# Sources that mean "host capture / attach", never substantive agent work.
_ATTACH_SOURCES = frozenset({"cmd_d", "process_attach", "ingest"})


def registry_entropy_score(decision: "GateDecision") -> float:
    """The ONLY number that may be written to ``agents.entropy_score``.

    Always ``decision.computed_H`` — message content entropy, not token H.
    """
    h = float(decision.computed_H)
    if not math.isfinite(h):
        return 0.0
    return h


def is_attach_status_noise(payload: Optional[dict[str, Any]] = None) -> bool:
    """True when this payload is ⌘D / process-attach traffic, not real work.

    Attach noise always produces the same short-status H (~2.38 for common
    templates). It must never refresh the registry score or be read as
    token-distribution collapse on the HUD.
    """
    p = payload or {}
    if str(p.get("event") or "").lower() == "ingest":
        return True
    if str(p.get("source") or "").lower() in _ATTACH_SOURCES:
        return True
    text = str(p.get("message") or p.get("text") or p.get("output") or "").strip()
    if _WORKING_IN_RE.match(text):
        return True
    return False


def should_refresh_registry_entropy(
    message_type: str,
    payload: Optional[dict[str, Any]] = None,
) -> bool:
    """Whether this message may overwrite ``agents.entropy_score``.

    Process-attach / ⌘D ingest posts the same short status forever; scoring
    each one freezes the Mac HUD on ~2.38 bits. Only substantive traffic
    (results, suggestions, benchmark updates, alerts, human asks) and
    *non-ingest* status lines refresh the registry score. Heartbeats still
    update ``last_seen_ns`` via ``update_agent_seen(..., update_entropy=False)``.
    """
    mt = (message_type or "").strip().lower()
    if mt in _REGISTRY_ENTROPY_TYPES:
        return True
    if mt != "status":
        return False
    if is_attach_status_noise(payload):
        return False
    text = str(
        (payload or {}).get("message")
        or (payload or {}).get("text")
        or (payload or {}).get("output")
        or ""
    ).strip()
    # Tiny status lines are heartbeats, not measurements worth showing as live H.
    if len(text) < 12:
        return False
    return True


def is_human_approval_request(msg: "AgentMessage") -> bool:
    """True when this message is an agent asking a human for yes/no."""
    if msg.message_type == "approval_needed":
        return True
    payload = msg.payload or {}
    return bool(payload.get("approval_needed") or payload.get("require_approval"))
