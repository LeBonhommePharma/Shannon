"""
agent_identity.py — single source of truth for named Shannon agents.

Used by agent_protocol, shannon_gate, and tests so Pill/hub never diverge on
labels for: grok_build, codex, claude_code, dispatch, cowork, science.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Optional


# The six primary agents required by product UX.
CORE_AGENT_IDS: tuple[str, ...] = (
    "grok_build",
    "codex",
    "claude_code",
    "dispatch",
    "cowork",
    "science",
)


@dataclass(frozen=True)
class AgentIdentity:
    id: str
    display_name: str
    short_name: str
    emoji: str
    # RGB 0..1 for Swift interop / docs
    color_rgb: tuple[float, float, float]
    system_image: str  # SF Symbol name for macOS surfaces
    auth_kind: str  # "local" | "cloud"
    # Companion animal — a fixed visual identity cue, one per agent. Purely
    # decorative-adjacent branding: it never varies with runtime state.
    #
    # NOTE: unrelated to pet_manager.py / ~/.shannon/pets/, which uses "pet" to
    # mean an agent's persistent memory directory. Same word, different concept.
    pet: str = "creature"
    # SF Symbol standing in for `pet`. SF Symbols has no owl/raven/fox/wolf/
    # beaver/dolphin glyph, so these are nearest-match and deliberately kept
    # distinct from one another — the animal *name* carries the identity.
    pet_symbol: str = "pawprint.fill"

    def as_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "display_name": self.display_name,
            "short_name": self.short_name,
            "emoji": self.emoji,
            "color_rgb": list(self.color_rgb),
            "system_image": self.system_image,
            "auth_kind": self.auth_kind,
            "pet": self.pet,
            "pet_symbol": self.pet_symbol,
        }


# Distinct brand cues: Science ≠ Grok Build ≠ Claude Code ≠ Codex ≠ Dispatch ≠ Cowork
IDENTITIES: dict[str, AgentIdentity] = {
    "science": AgentIdentity(
        id="science",
        display_name="Claude Science",
        short_name="Sci",
        emoji="🔬",
        color_rgb=(1.00, 0.72, 0.10),
        system_image="flask.fill",
        auth_kind="local",
        pet="owl",  # wise, observant — watches the run
        pet_symbol="bird.fill",
    ),
    "grok_build": AgentIdentity(
        id="grok_build",
        display_name="Grok Build",
        short_name="Grok",
        emoji="🟣",
        color_rgb=(0.68, 0.28, 0.98),
        system_image="sparkles",
        auth_kind="cloud",
        pet="raven",  # dark, clever, opportunistic
        pet_symbol="bird",
    ),
    "claude_code": AgentIdentity(
        id="claude_code",
        display_name="Claude Code",
        short_name="CC",
        emoji="🟠",
        color_rgb=(1.00, 0.50, 0.08),
        system_image="bubble.left.and.bubble.right.fill",
        auth_kind="local",
        pet="fox",  # quick, adaptive
        pet_symbol="hare.fill",
    ),
    "codex": AgentIdentity(
        id="codex",
        display_name="Codex",
        short_name="Codex",
        emoji="🔵",
        color_rgb=(0.30, 0.55, 1.00),
        system_image="chevron.left.forwardslash.chevron.right",
        auth_kind="cloud",
        pet="dolphin",  # intelligent, communicative
        pet_symbol="fish.fill",
    ),
    "dispatch": AgentIdentity(
        id="dispatch",
        display_name="Dispatch",
        short_name="Disp",
        emoji="🟤",
        color_rgb=(0.72, 0.50, 0.28),
        system_image="paperplane.fill",
        auth_kind="local",
        pet="wolf",  # coordinating, pack-oriented
        pet_symbol="dog.fill",
    ),
    "cowork": AgentIdentity(
        id="cowork",
        display_name="Cowork",
        short_name="CWork",
        emoji="🟢",
        color_rgb=(0.20, 0.85, 0.45),
        system_image="person.2.fill",
        auth_kind="local",
        pet="beaver",  # industrious builder
        pet_symbol="pawprint.fill",
    ),
}

# Extended optional agents (still valid on the wire)
IDENTITIES.update(
    {
        "chatgpt": AgentIdentity(
            id="chatgpt",
            display_name="ChatGPT",
            short_name="GPT",
            emoji="🟢",
            color_rgb=(0.10, 0.72, 0.55),
            system_image="text.bubble.fill",
            auth_kind="cloud",
            pet="parrot",  # fluent, conversational
            pet_symbol="bird.circle",
        ),
        "dataset_runner": AgentIdentity(
            id="dataset_runner",
            display_name="DatasetRunner",
            short_name="DR",
            emoji="📊",
            color_rgb=(0.15, 0.70, 0.80),
            system_image="tablecells",
            auth_kind="local",
            # Not an animal, unlike the rest — DatasetRunner is machinery,
            # grinding through entries rather than acting with intent.
            pet="gear",
            pet_symbol="gearshape.fill",
        ),
        "local_test": AgentIdentity(
            id="local_test",
            display_name="Local Test",
            short_name="Test",
            emoji="⚪️",
            color_rgb=(0.55, 0.55, 0.58),
            system_image="cpu",
            auth_kind="local",
            pet="ladybug",  # small, benign, a test subject
            pet_symbol="ladybug.fill",
        ),
        "terminal": AgentIdentity(
            id="terminal",
            display_name="Terminal",
            short_name="Term",
            emoji="⬛",
            color_rgb=(0.55, 0.60, 0.65),
            system_image="terminal.fill",
            auth_kind="local",
            pet="tortoise",  # old, slow, outlives everything
            pet_symbol="tortoise.fill",
        ),
        "browser": AgentIdentity(
            id="browser",
            display_name="Browser",
            short_name="Web",
            emoji="🌐",
            color_rgb=(0.35, 0.55, 0.95),
            system_image="globe",
            auth_kind="local",
            pet="gecko",  # clings to any surface
            pet_symbol="lizard.fill",
        ),
    }
)


def identity_for(agent_id: str) -> AgentIdentity:
    if agent_id in IDENTITIES:
        return IDENTITIES[agent_id]
    return AgentIdentity(
        id=agent_id,
        display_name=agent_id.replace("_", " ").title(),
        short_name=agent_id[:4].upper(),
        emoji="⚙️",
        color_rgb=(0.55, 0.55, 0.58),
        system_image="cpu",
        auth_kind="local",
    )


def label_for(agent_id: str) -> str:
    """Human label for UI lists: '🔬 Claude Science'."""
    ident = identity_for(agent_id)
    return f"{ident.emoji} {ident.display_name}"


# ── Status / ask pure reducers (testable without sockets) ─────────────────────


@dataclass
class AgentStatusUpdate:
    agent_id: str
    task_summary: str
    status: str  # active | idle | blocked | waiting
    event_type: str
    event_label: str


@dataclass
class PendingAsk:
    agent_id: str
    interaction_id: str
    prompt: str
    status: str  # pending | approved | denied


def status_from_payload(
    agent_id: str,
    message_type: str,
    payload: dict[str, Any],
) -> AgentStatusUpdate:
    """Map a gate message to a UI-facing status update (shipped entry point)."""
    text = str(
        payload.get("text")
        or payload.get("message")
        or payload.get("summary")
        or payload.get("task")
        or payload.get("output")
        or payload.get("label")
        or ""
    ).strip()
    if not text:
        text = message_type
    text = text[:200]

    status = "active"
    if message_type in ("alert",) or payload.get("blocked"):
        status = "blocked"
    elif payload.get("waiting") or message_type == "approval_needed":
        status = "waiting"
    elif payload.get("idle"):
        status = "idle"

    event_type = message_type
    if payload.get("approval_needed") or message_type == "approval_needed":
        event_type = "approval_needed"
    elif message_type == "result":
        event_type = "task_complete"

    return AgentStatusUpdate(
        agent_id=agent_id,
        task_summary=text,
        status=status,
        event_type=event_type,
        event_label=text or identity_for(agent_id).display_name,
    )


def ask_from_payload(
    agent_id: str,
    payload: dict[str, Any],
    interaction_id: Optional[str] = None,
    *,
    force: bool = False,
) -> Optional[PendingAsk]:
    """Build a pending ask if the payload requests human approval.

    Parameters
    ----------
    force:
        When True (e.g. message_type == approval_needed), create an ask even if
        the payload omits the approval_needed flag.
    """
    needs = force or (
        payload.get("approval_needed") is True
        or payload.get("require_approval") is True
        or str(payload.get("kind", "")).lower() in ("approval", "yes_no", "confirm")
    )
    if not needs:
        return None

    prompt = str(
        payload.get("prompt")
        or payload.get("question")
        or payload.get("text")
        or "Approval required"
    ).strip()[:300]
    iid = interaction_id or str(payload.get("interaction_id") or f"ask-{agent_id}")
    return PendingAsk(
        agent_id=agent_id,
        interaction_id=iid,
        prompt=prompt,
        status="pending",
    )


def resolve_ask(ask: PendingAsk, approved: bool) -> PendingAsk:
    """Return a new PendingAsk with approved/denied status."""
    return PendingAsk(
        agent_id=ask.agent_id,
        interaction_id=ask.interaction_id,
        prompt=ask.prompt,
        status="approved" if approved else "denied",
    )


def interaction_id_from_activity_output(
    event_output: str,
    agent_id: str,
    *,
    fallback_ts: Optional[float] = None,
) -> str:
    """Extract gate interaction_id from agent_activity.event_output.

    Mirrors HubAskPipeline.gateInteractionId in AgentHubApp.swift — the hub UI
    must use this id on Approve/Deny, never a freshly generated UUID.
    Gate writes bare ``ask.interaction_id`` into event_output for approval_needed.
    """
    import time as _time

    trimmed = (event_output or "").strip()
    if not trimmed:
        ts = int(fallback_ts if fallback_ts is not None else _time.time())
        return f"ask-{agent_id}-{ts}"
    if trimmed.startswith("{"):
        try:
            obj = json.loads(trimmed)
            if isinstance(obj, dict):
                iid = str(obj.get("interaction_id") or "").strip()
                if iid:
                    return iid
        except (json.JSONDecodeError, TypeError):
            pass
    if "\n" not in trimmed and len(trimmed) <= 200:
        return trimmed
    ts = int(fallback_ts if fallback_ts is not None else _time.time())
    return f"ask-{agent_id}-{ts}"


def hub_ui_resolve_payload(
    interaction_id: str,
    agent_id: str,
    approved: bool,
    reply: Optional[str] = None,
) -> dict[str, Any]:
    """Wire payload AgentHubApp sendApproval / HubAskPipeline.resolvePayload emit.

    The interaction_id field MUST be the gate row id (from agent_interactions or
    activity event_output), not a random UI UUID.
    """
    payload: dict[str, Any] = {
        "target_agent": agent_id,
        "approved": bool(approved),
        "interaction_id": interaction_id,
        "source": "hub_ui",
        "kind": "approval_response",
    }
    if reply and str(reply).strip():
        payload["user_reply"] = str(reply).strip()
    return payload


def core_identities() -> list[AgentIdentity]:
    return [IDENTITIES[i] for i in CORE_AGENT_IDS]
