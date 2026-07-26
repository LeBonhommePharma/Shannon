#!/usr/bin/env python3
"""
agent_manager.py — Shannon hub agent lifecycle handrail
=======================================================
Pure + live helpers for spawn / control / monitor / kill of hub agents.

Shannon is the *downstream* agentic management hub: whichever upstream API
(model endpoint) an agent uses, it must still register, heartbeat, report
status/results through the gate, and detach cleanly so concurrent FlexAIDdS
benchmarking stays coordinated.

This module is stdlib-first. Live socket/HTTP calls go through AgentClient.
Unit tests cover pure planners without a running gate.
"""

from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any, Optional

try:
    from agent_identity import (
        CORE_AGENT_IDS,
        HANDRAIL_AGENT_IDS,
        IDENTITIES,
        identity_for,
        label_for,
    )
except ImportError:  # package-style
    from hub.agent_identity import (  # type: ignore
        CORE_AGENT_IDS,
        HANDRAIL_AGENT_IDS,
        IDENTITIES,
        identity_for,
        label_for,
    )

SOCKET_PATH_DEFAULT = "/tmp/shannon.sock"
DEFAULT_HTTP_URL = "http://127.0.0.1:8765"


@dataclass(frozen=True)
class LifecyclePlan:
    """What a lifecycle action will do — pure, testable without a gate."""

    action: str  # spawn | control | monitor | kill | list | ask | send
    agent_id: str
    task_id: str
    mode: str  # socket | http
    message_type: str
    payload: dict[str, Any] = field(default_factory=dict)
    notes: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["payload"] = dict(self.payload)
        d["notes"] = list(self.notes)
        d["label"] = label_for(self.agent_id)
        return d


def normalize_agent_id(raw: str) -> str:
    """Map display names / aliases to canonical hub agent ids."""
    s = (raw or "").strip().lower().replace(" ", "_").replace("-", "_")
    aliases = {
        "grok": "grok_build",
        "grokbuild": "grok_build",
        "xai": "grok_build",
        "claude": "claude_code",
        "claude_code": "claude_code",
        "claudecode": "claude_code",
        "cc": "claude_code",
        "claude_science": "science",
        "claudescience": "science",
        "sci": "science",
        "science": "science",
        "claude_cowork": "cowork",
        "claudecowork": "cowork",
        "cowork": "cowork",
        "claude_dispatch": "dispatch",
        "claudedispatch": "dispatch",
        "dispatch": "dispatch",
        "openai_codex": "codex",
        "codex": "codex",
        "design": "design",
        "claude_design": "design",
        "claudedesign": "design",
        "des": "design",
        "opencode": "opencode",
        "open_code": "opencode",
        "oc": "opencode",
        "dataset": "dataset_runner",
        "dataset_runner": "dataset_runner",
        "dr": "dataset_runner",
    }
    if s in aliases:
        return aliases[s]
    if s in IDENTITIES:
        return s
    # Allow unknown only if it looks like a slug — identity_for still works.
    return s


def default_task_id(prefix: str = "session") -> str:
    return f"{prefix}_{int(time.time())}_{uuid.uuid4().hex[:8]}"


def gate_socket_up(socket_path: str = SOCKET_PATH_DEFAULT) -> bool:
    return os.path.exists(socket_path)


def plan_spawn(
    agent_id: str,
    task_id: Optional[str] = None,
    *,
    mode: str = "socket",
    reason: str = "spawn",
    details: Optional[dict[str, Any]] = None,
) -> LifecyclePlan:
    aid = normalize_agent_id(agent_id)
    tid = task_id or default_task_id(f"spawn_{aid}")
    payload: dict[str, Any] = {
        "message": f"spawn: {label_for(aid)} online ({reason})",
        "lifecycle": "spawn",
        "agent_id": aid,
        "task_id": tid,
    }
    if details:
        payload.update(details)
    notes = (
        "Registers with Shannon Gate and announces presence.",
        "Does not launch upstream model processes — that is the host TUI's job.",
        "Shannon handrail: all subsequent tool/spawn traffic must report via control/monitor.",
    )
    return LifecyclePlan(
        action="spawn",
        agent_id=aid,
        task_id=tid,
        mode=mode,
        message_type="status",
        payload=payload,
        notes=notes,
    )


def plan_control(
    agent_id: str,
    task_id: str,
    message: str,
    *,
    mode: str = "socket",
    details: Optional[dict[str, Any]] = None,
) -> LifecyclePlan:
    aid = normalize_agent_id(agent_id)
    payload: dict[str, Any] = {
        "message": message,
        "lifecycle": "control",
    }
    if details:
        payload.update(details)
    return LifecyclePlan(
        action="control",
        agent_id=aid,
        task_id=task_id,
        mode=mode,
        message_type="status",
        payload=payload,
        notes=("Progress / control plane status through the gate.",),
    )


def plan_kill(
    agent_id: str,
    task_id: str,
    *,
    mode: str = "socket",
    reason: str = "kill",
) -> LifecyclePlan:
    aid = normalize_agent_id(agent_id)
    payload = {
        "message": f"kill: {label_for(aid)} detaching ({reason})",
        "lifecycle": "kill",
        "severity": "info",
        "status": "offline",
    }
    return LifecyclePlan(
        action="kill",
        agent_id=aid,
        task_id=task_id,
        mode=mode,
        message_type="status",
        payload=payload,
        notes=(
            "Marks the agent offline at the hub and closes the socket session.",
            "Does not SIGKILL host TUI processes — pair with host-native cancel.",
        ),
    )


def plan_monitor(
    agent_id: str = "dispatch",
    task_id: Optional[str] = None,
    *,
    mode: str = "socket",
) -> LifecyclePlan:
    aid = normalize_agent_id(agent_id)
    tid = task_id or default_task_id("monitor")
    return LifecyclePlan(
        action="monitor",
        agent_id=aid,
        task_id=tid,
        mode=mode,
        message_type="query",
        payload={"query_type": "agent_list"},
        notes=("Read-only: connected agents + recent audit messages.",),
    )


def plan_ask(
    agent_id: str,
    task_id: str,
    prompt: str,
    *,
    mode: str = "socket",
    details: Optional[dict[str, Any]] = None,
) -> LifecyclePlan:
    aid = normalize_agent_id(agent_id)
    payload: dict[str, Any] = {
        "approval_needed": True,
        "prompt": prompt,
        "text": prompt,
        "lifecycle": "ask",
    }
    if details:
        payload.update(details)
    return LifecyclePlan(
        action="ask",
        agent_id=aid,
        task_id=task_id,
        mode=mode,
        message_type="approval_needed",
        payload=payload,
        notes=("Human gate via Shannon pill / hub UI.",),
    )


def plan_send_result(
    agent_id: str,
    task_id: str,
    result: dict[str, Any],
    *,
    mode: str = "socket",
    confidence: float = 0.9,
) -> LifecyclePlan:
    aid = normalize_agent_id(agent_id)
    payload = dict(result)
    payload.setdefault("lifecycle", "result")
    return LifecyclePlan(
        action="send",
        agent_id=aid,
        task_id=task_id,
        mode=mode,
        message_type="result",
        payload={**payload, "confidence": confidence},
        notes=("Primary gated output path (entropy scored).",),
    )


def handrail_roster() -> list[dict[str, Any]]:
    """Canonical roster for the Shannon skill (collaborative workers)."""
    out = []
    for aid in HANDRAIL_AGENT_IDS:
        ident = identity_for(aid)
        out.append(
            {
                "id": aid,
                "display_name": ident.display_name,
                "emoji": ident.emoji,
                "auth_kind": ident.auth_kind,
                "pet": ident.pet,
                "core": aid in CORE_AGENT_IDS,
            }
        )
    return out


# ── FlexAIDdS benchmark campaign ownership (Shannon-owned orchestration) ─────

# Serial heavy classic arms on one Mac. Shannon owns the campaign plan; agents
# are only delegated through this handrail (skill + CLI).
BENCHMARK_PHASES: tuple[str, ...] = ("A", "B0", "B")

# Only these agents may own a heavy docking arm (benchmark_update / DatasetRunner).
HEAVY_DOCKING_OWNER_IDS: frozenset[str] = frozenset({"dataset_runner"})

# Role → default hub agent id for campaign delegation.
CAMPAIGN_ROLE_DEFAULTS: dict[str, str] = {
    "docking_owner": "dataset_runner",
    "owner": "dataset_runner",
    "dataset_runner": "dataset_runner",
    "science_analyst": "science",
    "analyst": "science",
    "science": "science",
    "code_claude": "claude_code",
    "claude_code": "claude_code",
    "code_codex": "codex",
    "codex": "codex",
    "code_grok": "grok_build",
    "grok_build": "grok_build",
    "coordinator": "dispatch",
    "dispatch": "dispatch",
    "design": "design",
    "cowork": "cowork",
    "opencode": "opencode",
}


@dataclass(frozen=True)
class CampaignPlan:
    """Shannon-owned FlexAIDdS campaign plan — pure, dry-runable, no gate."""

    action: str  # always "campaign"
    campaign: str
    task_id: str
    phases: tuple[str, ...]
    owner_agent_id: str
    owner_role: str
    delegations: tuple[dict[str, Any], ...]
    refused: bool = False
    refuse_reason: str = ""
    existing_heavy_owner: str = ""
    notes: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "campaign": self.campaign,
            "task_id": self.task_id,
            "phases": list(self.phases),
            "owner_agent_id": self.owner_agent_id,
            "owner_role": self.owner_role,
            "delegations": [dict(d) for d in self.delegations],
            "refused": self.refused,
            "refuse_reason": self.refuse_reason or None,
            "existing_heavy_owner": self.existing_heavy_owner or None,
            "notes": list(self.notes),
            "ok": not self.refused,
            # Never invent science metrics.
            "fabricated_entropy": None,
            "fabricated_cf": None,
        }


def resolve_campaign_role(role: str, agent_id: Optional[str] = None) -> tuple[str, str]:
    """Return (role_key, canonical_agent_id) for a campaign role."""
    key = (role or "").strip().lower().replace(" ", "_").replace("-", "_")
    if agent_id:
        return key or "custom", normalize_agent_id(agent_id)
    if key in CAMPAIGN_ROLE_DEFAULTS:
        return key, CAMPAIGN_ROLE_DEFAULTS[key]
    # Treat bare agent ids as roles that map to themselves.
    aid = normalize_agent_id(key)
    return key or aid, aid


def is_heavy_docking_owner(agent_id: str) -> bool:
    return normalize_agent_id(agent_id) in HEAVY_DOCKING_OWNER_IDS


def find_existing_heavy_owner(
    connected: Optional[list[str]] = None,
    *,
    agent_tasks: Optional[dict[str, str]] = None,
    campaign_task_id: Optional[str] = None,
) -> Optional[str]:
    """
    Pure: if monitor state already shows a heavy docking owner, return their id.

    When ``agent_tasks`` + ``campaign_task_id`` are provided, only owners whose
    task shares the campaign prefix are counted (same campaign). Without task
    attribution, any connected heavy owner blocks a second heavy spawn.
    """
    connected = connected or []
    agent_tasks = agent_tasks or {}
    campaign_prefix = ""
    if campaign_task_id:
        # flexaidds_redpair_YYYYMMDD_xxx → flexaidds_redpair_YYYYMMDD
        parts = campaign_task_id.split("_")
        campaign_prefix = "_".join(parts[:3]) if len(parts) >= 3 else campaign_task_id

    for raw in connected:
        aid = normalize_agent_id(str(raw))
        if not is_heavy_docking_owner(aid):
            continue
        if campaign_prefix and agent_tasks:
            tid = agent_tasks.get(aid) or agent_tasks.get(raw) or ""
            if tid and campaign_prefix not in tid and tid != campaign_task_id:
                continue
        return aid
    return None


def plan_delegate(
    role: str,
    task_id: str,
    *,
    agent_id: Optional[str] = None,
    mode: str = "socket",
    reason: str = "campaign_delegate",
    monitor_connected: Optional[list[str]] = None,
    agent_tasks: Optional[dict[str, str]] = None,
) -> dict[str, Any]:
    """
    Plan a single role delegation (spawn) under Shannon ownership.

    Refuses when the role is a heavy docking owner and monitor already shows one.
    Analyst/coder roles always succeed (pure plan).
    """
    role_key, aid = resolve_campaign_role(role, agent_id)
    existing = None
    if is_heavy_docking_owner(aid):
        existing = find_existing_heavy_owner(
            monitor_connected,
            agent_tasks=agent_tasks,
            campaign_task_id=task_id,
        )
        if existing:
            return {
                "action": "delegate",
                "role": role_key,
                "agent_id": aid,
                "task_id": task_id,
                "refused": True,
                "ok": False,
                "refuse_reason": (
                    f"Heavy docking arm already owned by {existing} — "
                    "monitor first; one heavy arm at a time (A→B0→B)."
                ),
                "existing_heavy_owner": existing,
                "plan": None,
            }
    spawn = plan_spawn(
        aid,
        task_id,
        mode=mode,
        reason=reason,
        details={"campaign_role": role_key, "shannon_owned": True},
    )
    return {
        "action": "delegate",
        "role": role_key,
        "agent_id": aid,
        "task_id": task_id,
        "refused": False,
        "ok": True,
        "refuse_reason": None,
        "existing_heavy_owner": None,
        "plan": spawn.as_dict(),
    }


def plan_benchmark_campaign(
    campaign: str = "red-pair",
    task_id: Optional[str] = None,
    *,
    owner: str = "dataset_runner",
    analysts: Optional[list[str]] = None,
    coders: Optional[list[str]] = None,
    coordinator: str = "dispatch",
    mode: str = "socket",
    monitor_connected: Optional[list[str]] = None,
    agent_tasks: Optional[dict[str, str]] = None,
    phases: Optional[tuple[str, ...]] = None,
) -> CampaignPlan:
    """
    Shannon-owned FlexAIDdS campaign plan.

    Owns orchestration: stable task id, serial phases A→B0→B, single docking
    owner (default ``dataset_runner``), and delegated analyst/coder/coordinator
    roles. Pure — no gate, no fabricated CF/entropy.

    Dual-owner rule: if ``monitor_connected`` already lists a heavy owner for
    this campaign, the plan is **refused** (ok=False) and includes no owner
    spawn; non-owner roles may still appear as refused-owner-only failure.
    """
    camp = (campaign or "red-pair").strip().lower().replace(" ", "_")
    tid = task_id or default_task_id(f"flexaidds_{camp}")
    owner_role, owner_aid = resolve_campaign_role("docking_owner", owner)
    phase_tuple = phases or BENCHMARK_PHASES

    existing = find_existing_heavy_owner(
        monitor_connected,
        agent_tasks=agent_tasks,
        campaign_task_id=tid,
    )
    notes = (
        "Shannon owns this campaign plan — agents only act via skill/CLI lifecycle.",
        "Heavy docking owner is dataset_runner (or explicit alias); one arm at a time.",
        "No fabricated CF, RMSD, or entropy in the plan — those come from live results only.",
        "monitor first before any second docking owner spawn.",
    )

    if existing and is_heavy_docking_owner(owner_aid):
        return CampaignPlan(
            action="campaign",
            campaign=camp,
            task_id=tid,
            phases=phase_tuple,
            owner_agent_id=owner_aid,
            owner_role=owner_role,
            delegations=(),
            refused=True,
            refuse_reason=(
                f"Heavy docking arm already owned by {existing} — "
                "do not dual-launch; wait or kill existing owner first."
            ),
            existing_heavy_owner=existing,
            notes=notes,
        )

    delegations: list[dict[str, Any]] = []

    def _add(role: str, agent: Optional[str] = None) -> None:
        d = plan_delegate(
            role,
            tid,
            agent_id=agent,
            mode=mode,
            reason=f"campaign:{camp}",
            monitor_connected=monitor_connected,
            agent_tasks=agent_tasks,
        )
        delegations.append(d)

    _add("docking_owner", owner_aid)
    for a in analysts or ["science"]:
        _add("science_analyst" if normalize_agent_id(a) == "science" else a, a)
    for c in coders or []:
        _add(c, c)
    if coordinator:
        _add("coordinator", coordinator)

    # If any heavy-owner delegation refused mid-list, mark campaign refused.
    refused_owner = any(
        d.get("refused") and is_heavy_docking_owner(str(d.get("agent_id") or ""))
        for d in delegations
    )
    existing2 = existing or next(
        (
            str(d.get("existing_heavy_owner"))
            for d in delegations
            if d.get("existing_heavy_owner")
        ),
        "",
    )

    return CampaignPlan(
        action="campaign",
        campaign=camp,
        task_id=tid,
        phases=phase_tuple,
        owner_agent_id=owner_aid,
        owner_role=owner_role,
        delegations=tuple(delegations),
        refused=refused_owner,
        refuse_reason=(
            f"Heavy docking arm already owned by {existing2}"
            if refused_owner
            else ""
        ),
        existing_heavy_owner=existing2 or "",
        notes=notes,
    )


# ── Claude Code ↔ Codex pair work (half-and-half + cross-review) ─────────────

# Default coding pair for Shannon-owned dual-agent tasks.
PAIR_AGENT_A = "claude_code"
PAIR_AGENT_B = "codex"

# Modes for plan_pair_work (skill-aligned).
PAIR_MODES: frozenset[str] = frozenset(
    {
        "implement_pair",  # both implement half-and-half
        "cross_review",  # mutual: each reviews the other's implement slice
        "claude_implements",  # Claude implements; Codex reviews
        "codex_implements",  # Codex implements; Claude reviews
        "implement_only",  # single agent implements (not a pair requirement)
    }
)


@dataclass(frozen=True)
class PairWorkPlan:
    """Shannon-owned dual-agent coding plan (Claude Code ↔ Codex). Pure."""

    action: str  # always "pair"
    mode: str
    task_id: str
    summary: str
    assignments: tuple[dict[str, Any], ...]
    refused: bool = False
    refuse_reason: str = ""
    notes: tuple[str, ...] = ()

    def as_dict(self) -> dict[str, Any]:
        return {
            "action": self.action,
            "mode": self.mode,
            "task_id": self.task_id,
            "summary": self.summary,
            "assignments": [dict(a) for a in self.assignments],
            "refused": self.refused,
            "refuse_reason": self.refuse_reason or None,
            "notes": list(self.notes),
            "ok": not self.refused,
            # Role/slice assignment only — never invent review text or code.
            "fabricated_review": None,
            "fabricated_code": None,
            "agents": sorted(
                {
                    str(a.get("agent_id"))
                    for a in self.assignments
                    if a.get("agent_id")
                }
            ),
        }


def _pair_assignment(
    agent_id: str,
    role: str,
    slice_label: str,
    task_id: str,
    *,
    mode: str = "socket",
    reason: str = "pair_work",
    reviews_agent: Optional[str] = None,
    implements_with: Optional[str] = None,
) -> dict[str, Any]:
    """One inspectable assignment + lifecycle spawn plan under shared task id."""
    aid = normalize_agent_id(agent_id)
    spawn = plan_spawn(
        aid,
        task_id,
        mode=mode,
        reason=reason,
        details={
            "pair_role": role,
            "slice": slice_label,
            "shannon_owned": True,
            "pair_work": True,
            **({"reviews_agent": reviews_agent} if reviews_agent else {}),
            **({"implements_with": implements_with} if implements_with else {}),
        },
    )
    return {
        "agent_id": aid,
        "role": role,  # implement | review
        "slice": slice_label,
        "reviews_agent": reviews_agent,
        "implements_with": implements_with,
        "plan": spawn.as_dict(),
    }


def plan_pair_work(
    mode: str = "implement_pair",
    task_id: Optional[str] = None,
    *,
    summary: str = "",
    agent_a: str = PAIR_AGENT_A,
    agent_b: str = PAIR_AGENT_B,
    socket_mode: str = "socket",
) -> PairWorkPlan:
    """
    Shannon-owned Claude Code ↔ Codex pair plan.

    Modes
    -----
    implement_pair
        Both implement half-and-half (slice_a / slice_b). Shared task id.
    cross_review
        Mutual: A implements slice_a and reviews B's slice_b; B implements
        slice_b and reviews A's slice_a (vice-versa review).
    claude_implements
        Claude Code implements full task; Codex reviews.
    codex_implements
        Codex implements full task; Claude Code reviews.
    implement_only
        Single agent (agent_a) implements — not a pair requirement.

    Pure: no gate, no host TUI launch, no invented review text or code.
    """
    m = (mode or "implement_pair").strip().lower().replace("-", "_").replace(" ", "_")
    # Aliases
    aliases = {
        "pair": "implement_pair",
        "half": "implement_pair",
        "half_and_half": "implement_pair",
        "mutual_review": "cross_review",
        "cross": "cross_review",
        "claude_impl": "claude_implements",
        "codex_impl": "codex_implements",
        "solo": "implement_only",
        "single": "implement_only",
    }
    m = aliases.get(m, m)

    notes = (
        "Shannon owns this pair plan — agents only act via skill/CLI lifecycle.",
        "Half-and-half is a role/slice assignment, not automatic file partitioning.",
        "No fabricated review comments or code in the plan — agents produce those live.",
    )
    tid = task_id or default_task_id("pair")
    a = normalize_agent_id(agent_a)
    b = normalize_agent_id(agent_b)
    title = (summary or "").strip() or "pair work"

    if m not in PAIR_MODES:
        return PairWorkPlan(
            action="pair",
            mode=m,
            task_id=tid,
            summary=title,
            assignments=(),
            refused=True,
            refuse_reason=(
                f"Unknown pair mode {m!r}; use one of: "
                + ", ".join(sorted(PAIR_MODES))
            ),
            notes=notes,
        )

    if m != "implement_only" and a == b:
        return PairWorkPlan(
            action="pair",
            mode=m,
            task_id=tid,
            summary=title,
            assignments=(),
            refused=True,
            refuse_reason=(
                "Pair mode requires two distinct agents "
                f"(got {a!r} twice). Use implement_only for a single agent."
            ),
            notes=notes,
        )

    assignments: list[dict[str, Any]] = []

    if m == "implement_pair":
        assignments.append(
            _pair_assignment(
                a,
                "implement",
                "slice_a",
                tid,
                mode=socket_mode,
                reason=f"pair:implement:{title[:40]}",
                implements_with=b,
            )
        )
        assignments.append(
            _pair_assignment(
                b,
                "implement",
                "slice_b",
                tid,
                mode=socket_mode,
                reason=f"pair:implement:{title[:40]}",
                implements_with=a,
            )
        )
    elif m == "cross_review":
        # Each implements one slice and reviews the other.
        assignments.append(
            _pair_assignment(
                a,
                "implement",
                "slice_a",
                tid,
                mode=socket_mode,
                reason=f"pair:impl_cross:{title[:40]}",
                implements_with=b,
            )
        )
        assignments.append(
            _pair_assignment(
                b,
                "implement",
                "slice_b",
                tid,
                mode=socket_mode,
                reason=f"pair:impl_cross:{title[:40]}",
                implements_with=a,
            )
        )
        assignments.append(
            _pair_assignment(
                a,
                "review",
                "slice_b",
                tid,
                mode=socket_mode,
                reason=f"pair:review_cross:{title[:40]}",
                reviews_agent=b,
            )
        )
        assignments.append(
            _pair_assignment(
                b,
                "review",
                "slice_a",
                tid,
                mode=socket_mode,
                reason=f"pair:review_cross:{title[:40]}",
                reviews_agent=a,
            )
        )
    elif m == "claude_implements":
        # Force Claude as implementer, Codex as reviewer regardless of agent_a/b
        # order when defaults used; still respect explicit agent_a/agent_b if set
        # to claude_code/codex.
        impl, rev = a, b
        if a == PAIR_AGENT_B and b == PAIR_AGENT_A:
            impl, rev = PAIR_AGENT_A, PAIR_AGENT_B
        elif "claude" in a or a == PAIR_AGENT_A:
            impl, rev = a, b
        elif "codex" in a or a == PAIR_AGENT_B:
            impl, rev = b, a
        else:
            impl, rev = PAIR_AGENT_A, PAIR_AGENT_B
        assignments.append(
            _pair_assignment(
                impl,
                "implement",
                "full",
                tid,
                mode=socket_mode,
                reason=f"pair:claude_impl:{title[:40]}",
            )
        )
        assignments.append(
            _pair_assignment(
                rev,
                "review",
                "full",
                tid,
                mode=socket_mode,
                reason=f"pair:codex_review:{title[:40]}",
                reviews_agent=impl,
            )
        )
    elif m == "codex_implements":
        impl, rev = PAIR_AGENT_B, PAIR_AGENT_A
        if a == PAIR_AGENT_B or "codex" in a:
            impl, rev = a, b
        elif b == PAIR_AGENT_B or "codex" in b:
            impl, rev = b, a
        assignments.append(
            _pair_assignment(
                impl,
                "implement",
                "full",
                tid,
                mode=socket_mode,
                reason=f"pair:codex_impl:{title[:40]}",
            )
        )
        assignments.append(
            _pair_assignment(
                rev,
                "review",
                "full",
                tid,
                mode=socket_mode,
                reason=f"pair:claude_review:{title[:40]}",
                reviews_agent=impl,
            )
        )
    else:  # implement_only
        assignments.append(
            _pair_assignment(
                a,
                "implement",
                "full",
                tid,
                mode=socket_mode,
                reason=f"pair:solo:{title[:40]}",
            )
        )

    return PairWorkPlan(
        action="pair",
        mode=m,
        task_id=tid,
        summary=title,
        assignments=tuple(assignments),
        refused=False,
        refuse_reason="",
        notes=notes,
    )


def format_monitor_report(
    connected: list[str],
    recent: list[dict[str, Any]],
    *,
    limit: int = 12,
) -> str:
    lines = ["Shannon hub monitor", f"connected ({len(connected)}):"]
    if not connected:
        lines.append("  (none)")
    else:
        for aid in connected:
            lines.append(f"  - {label_for(aid)} ({aid})")
    lines.append(f"recent messages (≤{limit}):")
    for msg in recent[:limit]:
        aid = msg.get("agent_id") or msg.get("from") or "?"
        mtype = msg.get("message_type") or msg.get("type") or "?"
        snippet = ""
        pl = msg.get("payload")
        if isinstance(pl, dict):
            snippet = str(pl.get("message") or pl.get("text") or pl.get("prompt") or "")[:80]
        elif isinstance(pl, str):
            snippet = pl[:80]
        lines.append(f"  [{aid}] {mtype}: {snippet}")
    if not recent:
        lines.append("  (none)")
    return "\n".join(lines)


class AgentManager:
    """Live hub lifecycle controller (uses AgentClient)."""

    def __init__(
        self,
        *,
        mode: str = "socket",
        http_url: str = DEFAULT_HTTP_URL,
        socket_path: str = SOCKET_PATH_DEFAULT,
    ) -> None:
        self.mode = mode
        self.http_url = http_url
        self.socket_path = socket_path

    def _client(self, agent_id: str, task_id: str):
        try:
            from agent_protocol import AgentClient, SOCKET_PATH as _sock
        except ImportError:
            from hub.agent_protocol import AgentClient  # type: ignore
            from hub.agent_protocol import SOCKET_PATH as _sock  # type: ignore

        # Honour custom socket path for tests.
        import agent_protocol as ap  # type: ignore

        if self.socket_path != _sock:
            ap.SOCKET_PATH = self.socket_path

        return AgentClient(
            normalize_agent_id(agent_id),
            task_id,
            mode=self.mode,
            http_url=self.http_url,
        )

    def spawn(
        self,
        agent_id: str,
        task_id: Optional[str] = None,
        *,
        reason: str = "spawn",
        details: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        plan = plan_spawn(agent_id, task_id, mode=self.mode, reason=reason, details=details)
        with self._client(plan.agent_id, plan.task_id) as c:
            decision = c.send_status(
                str(plan.payload.get("message", "spawn")),
                details={k: v for k, v in plan.payload.items() if k != "message"},
            )
        return {"plan": plan.as_dict(), "decision": decision, "ok": True}

    def control(
        self,
        agent_id: str,
        task_id: str,
        message: str,
        *,
        details: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        plan = plan_control(agent_id, task_id, message, mode=self.mode, details=details)
        with self._client(plan.agent_id, plan.task_id) as c:
            decision = c.send_status(message, details=details)
        return {"plan": plan.as_dict(), "decision": decision, "ok": True}

    def kill(
        self,
        agent_id: str,
        task_id: str,
        *,
        reason: str = "kill",
    ) -> dict[str, Any]:
        plan = plan_kill(agent_id, task_id, mode=self.mode, reason=reason)
        with self._client(plan.agent_id, plan.task_id) as c:
            decision = c.send_status(
                str(plan.payload["message"]),
                details={"lifecycle": "kill", "status": "offline", "reason": reason},
            )
        return {"plan": plan.as_dict(), "decision": decision, "ok": True}

    def ask(
        self,
        agent_id: str,
        task_id: str,
        prompt: str,
        *,
        details: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        plan = plan_ask(agent_id, task_id, prompt, mode=self.mode, details=details)
        with self._client(plan.agent_id, plan.task_id) as c:
            decision = c.send_approval_needed(prompt, details=details)
        return {"plan": plan.as_dict(), "decision": decision, "ok": True}

    def send_result(
        self,
        agent_id: str,
        task_id: str,
        result: dict[str, Any],
        *,
        confidence: float = 0.9,
    ) -> dict[str, Any]:
        plan = plan_send_result(
            agent_id, task_id, result, mode=self.mode, confidence=confidence
        )
        with self._client(plan.agent_id, plan.task_id) as c:
            decision = c.send_result(result, confidence=confidence)
        return {"plan": plan.as_dict(), "decision": decision, "ok": True}

    def monitor(self, agent_id: str = "dispatch", task_id: Optional[str] = None) -> dict[str, Any]:
        plan = plan_monitor(agent_id, task_id, mode=self.mode)
        with self._client(plan.agent_id, plan.task_id) as c:
            agents = c.query_agent_list()
            recent = c.query_recent_messages(limit=20)
        connected = []
        if isinstance(agents, dict):
            connected = list(agents.get("connected") or agents.get("agents") or [])
        report = format_monitor_report(connected, list(recent or []))
        return {
            "plan": plan.as_dict(),
            "connected": connected,
            "recent": recent,
            "report": report,
            "ok": True,
        }

    def list_roster(self) -> dict[str, Any]:
        return {
            "handrail": handrail_roster(),
            "gate_up": gate_socket_up(self.socket_path) if self.mode == "socket" else None,
            "ok": True,
        }

    def prefer_device(
        self,
        devices: list[dict[str, Any]],
        *,
        busy_threshold: float = 85.0,
    ) -> dict[str, Any]:
        """Load-preference for concurrent benchmarking (pure, no gate required)."""
        try:
            from load_balance import preferred_device, should_defer_work
        except ImportError:
            from hub.load_balance import preferred_device, should_defer_work  # type: ignore
        pick = preferred_device(devices, busy_threshold=busy_threshold)
        return {
            "preferred": pick,
            "should_defer": should_defer_work(pick) if pick else True,
            "ok": pick is not None,
        }


def main(argv: Optional[list[str]] = None) -> int:
    """CLI: PYTHONPATH=hub python3 -m agent_manager <cmd> ..."""
    import argparse

    # Shared flags on every subcommand so `cmd --json` works (not only pre-cmd).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--mode", choices=("socket", "http"), default="socket")
    common.add_argument("--http-url", default=DEFAULT_HTTP_URL)
    common.add_argument("--socket", default=SOCKET_PATH_DEFAULT)
    common.add_argument("--json", action="store_true", help="machine-readable output")

    p = argparse.ArgumentParser(prog="shannon-hub", description="Shannon hub agent manager")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("spawn", parents=[common], help="Register agent and announce online")
    sp.add_argument("agent")
    sp.add_argument("--task", default=None)
    sp.add_argument("--reason", default="spawn")
    sp.add_argument("--dry-run", action="store_true")

    cp = sub.add_parser("control", parents=[common], help="Send control/status line")
    cp.add_argument("agent")
    cp.add_argument("message")
    cp.add_argument("--task", required=True)
    cp.add_argument("--dry-run", action="store_true")

    kp = sub.add_parser("kill", parents=[common], help="Detach agent (hub offline status)")
    kp.add_argument("agent")
    kp.add_argument("--task", required=True)
    kp.add_argument("--reason", default="kill")
    kp.add_argument("--dry-run", action="store_true")

    mp = sub.add_parser(
        "monitor", parents=[common], help="List connected agents + recent messages"
    )
    mp.add_argument("--agent", default="dispatch")
    mp.add_argument("--task", default=None)
    mp.add_argument("--dry-run", action="store_true")

    ap_ = sub.add_parser("ask", parents=[common], help="Request human approval via pill")
    ap_.add_argument("agent")
    ap_.add_argument("prompt")
    ap_.add_argument("--task", required=True)
    ap_.add_argument("--dry-run", action="store_true")

    rp = sub.add_parser(
        "result", parents=[common], help="Send gated result payload (JSON string or -)"
    )
    rp.add_argument("agent")
    rp.add_argument("--task", required=True)
    rp.add_argument("--payload", required=True, help='JSON object, or "-" for stdin')
    rp.add_argument("--confidence", type=float, default=0.9)
    rp.add_argument("--dry-run", action="store_true")

    sub.add_parser("roster", parents=[common], help="Print handrail agent roster")
    sub.add_parser("gate-status", parents=[common], help="Is the local gate socket up?")

    pref = sub.add_parser(
        "prefer-device",
        parents=[common],
        help="Pick least constrained device from JSON list (stdin or --devices)",
    )
    pref.add_argument(
        "--devices",
        default="-",
        help='JSON array of device capacity dicts, or "-" for stdin',
    )
    pref.add_argument("--busy-threshold", type=float, default=85.0)

    # Shannon-owned FlexAIDdS campaign (skill surface — dry-run never needs gate).
    camp = sub.add_parser(
        "campaign",
        parents=[common],
        help="Plan a Shannon-owned FlexAIDdS benchmark campaign (delegate agents)",
    )
    camp.add_argument(
        "--campaign",
        default="red-pair",
        help="Campaign name (default red-pair)",
    )
    camp.add_argument("--task", default=None, help="Stable task id (auto if omitted)")
    camp.add_argument(
        "--owner",
        default="dataset_runner",
        help="Heavy docking owner agent id (default dataset_runner)",
    )
    camp.add_argument(
        "--analysts",
        default="science",
        help="Comma-separated analyst agent ids (default science)",
    )
    camp.add_argument(
        "--coders",
        default="",
        help="Comma-separated coder agent ids (e.g. claude_code,codex,grok_build)",
    )
    camp.add_argument(
        "--coordinator",
        default="dispatch",
        help="Coordinator agent id (default dispatch)",
    )
    camp.add_argument(
        "--connected",
        default="",
        help="Synthetic monitor roster (comma-separated agent ids already online)",
    )
    camp.add_argument(
        "--dry-run",
        action="store_true",
        help="Print pure plan only (always safe; no gate)",
    )

    dlg = sub.add_parser(
        "delegate",
        parents=[common],
        help="Plan one role delegation under Shannon ownership",
    )
    dlg.add_argument("role", help="Role or agent id (docking_owner, science, codex, …)")
    dlg.add_argument("--agent", default=None, help="Override agent id for the role")
    dlg.add_argument("--task", required=True, help="Campaign task id")
    dlg.add_argument(
        "--connected",
        default="",
        help="Synthetic monitor roster (comma ids) for dual-owner check",
    )
    dlg.add_argument("--dry-run", action="store_true")

    # Claude Code ↔ Codex pair work (half-and-half implement + cross-review).
    pr = sub.add_parser(
        "pair",
        parents=[common],
        help="Plan Shannon-owned Claude Code ↔ Codex pair work (implement/review)",
    )
    pr.add_argument(
        "--pair-mode",
        default="implement_pair",
        dest="pair_mode",
        help=(
            "implement_pair | cross_review | claude_implements | "
            "codex_implements | implement_only "
            "(not --mode: that is socket|http on common flags)"
        ),
    )
    pr.add_argument("--task", default=None, help="Shared task id (auto if omitted)")
    pr.add_argument(
        "--summary",
        default="",
        help="Short description of the work (no code/review body inventing)",
    )
    pr.add_argument(
        "--agent-a",
        default=PAIR_AGENT_A,
        help=f"First agent id (default {PAIR_AGENT_A})",
    )
    pr.add_argument(
        "--agent-b",
        default=PAIR_AGENT_B,
        help=f"Second agent id (default {PAIR_AGENT_B})",
    )
    pr.add_argument(
        "--dry-run",
        action="store_true",
        help="Print pure plan only (always safe; no gate)",
    )

    args = p.parse_args(argv)
    mgr = AgentManager(mode=args.mode, http_url=args.http_url, socket_path=args.socket)

    def out(obj: Any) -> None:
        if args.json:
            print(json.dumps(obj, indent=2, default=str))
        elif isinstance(obj, dict) and "report" in obj:
            print(obj["report"])
        elif isinstance(obj, dict):
            print(json.dumps(obj, indent=2, default=str))
        else:
            print(obj)

    try:
        if args.cmd == "roster":
            out(mgr.list_roster())
            return 0
        if args.cmd == "gate-status":
            up = gate_socket_up(args.socket)
            out({"gate_up": up, "socket": args.socket})
            return 0 if up else 2
        if args.cmd == "prefer-device":
            raw = args.devices
            if raw == "-":
                raw = sys.stdin.read()
            devices = json.loads(raw)
            if not isinstance(devices, list):
                raise SystemExit("prefer-device expects a JSON array of devices")
            result = mgr.prefer_device(devices, busy_threshold=args.busy_threshold)
            out(result)
            return 0 if result.get("ok") else 1

        if args.cmd == "spawn":
            plan = plan_spawn(args.agent, args.task, mode=args.mode, reason=args.reason)
            if args.dry_run:
                out(plan.as_dict())
                return 0
            out(mgr.spawn(args.agent, args.task, reason=args.reason))
            return 0

        if args.cmd == "control":
            plan = plan_control(args.agent, args.task, args.message, mode=args.mode)
            if args.dry_run:
                out(plan.as_dict())
                return 0
            out(mgr.control(args.agent, args.task, args.message))
            return 0

        if args.cmd == "kill":
            plan = plan_kill(args.agent, args.task, mode=args.mode, reason=args.reason)
            if args.dry_run:
                out(plan.as_dict())
                return 0
            out(mgr.kill(args.agent, args.task, reason=args.reason))
            return 0

        if args.cmd == "monitor":
            plan = plan_monitor(args.agent, args.task, mode=args.mode)
            if args.dry_run:
                out(plan.as_dict())
                return 0
            out(mgr.monitor(args.agent, args.task))
            return 0

        if args.cmd == "ask":
            plan = plan_ask(args.agent, args.task, args.prompt, mode=args.mode)
            if args.dry_run:
                out(plan.as_dict())
                return 0
            out(mgr.ask(args.agent, args.task, args.prompt))
            return 0

        if args.cmd == "result":
            raw = args.payload
            if raw == "-":
                import sys

                raw = sys.stdin.read()
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise SystemExit("result payload must be a JSON object")
            plan = plan_send_result(
                args.agent, args.task, payload, mode=args.mode, confidence=args.confidence
            )
            if args.dry_run:
                out(plan.as_dict())
                return 0
            out(
                mgr.send_result(
                    args.agent, args.task, payload, confidence=args.confidence
                )
            )
            return 0

        if args.cmd == "campaign":
            def _split(s: str) -> list[str]:
                return [x.strip() for x in (s or "").split(",") if x.strip()]

            connected = _split(getattr(args, "connected", "") or "")
            plan = plan_benchmark_campaign(
                args.campaign,
                args.task,
                owner=args.owner,
                analysts=_split(args.analysts) or ["science"],
                coders=_split(args.coders),
                coordinator=args.coordinator,
                mode=args.mode,
                monitor_connected=connected or None,
            )
            # Campaign planning is always pure; --dry-run is the supported path.
            # Live multi-TUI launch is out of scope — always emit the plan.
            out(plan.as_dict())
            return 0 if not plan.refused else 3

        if args.cmd == "delegate":
            connected = [
                x.strip()
                for x in (getattr(args, "connected", "") or "").split(",")
                if x.strip()
            ]
            result = plan_delegate(
                args.role,
                args.task,
                agent_id=args.agent,
                mode=args.mode,
                monitor_connected=connected or None,
            )
            out(result)
            return 0 if result.get("ok") else 3

        if args.cmd == "pair":
            plan = plan_pair_work(
                getattr(args, "pair_mode", "implement_pair"),
                args.task,
                summary=getattr(args, "summary", "") or "",
                agent_a=getattr(args, "agent_a", PAIR_AGENT_A),
                agent_b=getattr(args, "agent_b", PAIR_AGENT_B),
                socket_mode=args.mode,
            )
            out(plan.as_dict())
            return 0 if not plan.refused else 3
    except ConnectionError as exc:
        out({"ok": False, "error": f"gate offline: {exc}"})
        return 1
    except Exception as exc:  # noqa: BLE001
        out({"ok": False, "error": str(exc)})
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
