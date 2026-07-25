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
    except ConnectionError as exc:
        out({"ok": False, "error": f"gate offline: {exc}"})
        return 1
    except Exception as exc:  # noqa: BLE001
        out({"ok": False, "error": str(exc)})
        return 1

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
