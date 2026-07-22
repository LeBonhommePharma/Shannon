#!/usr/bin/env python3
"""
pet_manager.py — Shannon Hub Pet System (Python side)
======================================================
Manages per-agent persistent identity under ~/.shannon/pets/{agent_id}/.

Directory layout per agent
--------------------------
  ~/.shannon/pets/{agent_id}/
      memory.md      — accumulated knowledge, past results, hypotheses
      config.json    — behavioural preferences, voice settings, thresholds
      history.jsonl  — per-turn messages, decisions, entropy scores
      state.json     — current status: active/idle, last task, resumable

Used by
-------
  shannon_gate.py   — reads memory.md for D_agents divergence detection;
                       writes state.json, history.jsonl after each turn;
                       logs "pet_memory_access" event to agent_activity.

Standalone CLI
--------------
  python pet_manager.py status [agent_id]
  python pet_manager.py set-task <agent_id> "<task summary>"
  python pet_manager.py mark-idle <agent_id>
  python pet_manager.py log-history <agent_id> '<json line>'
  python pet_manager.py read-memory <agent_id> [--bytes 512]
  python pet_manager.py reset <agent_id>
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

# ── Configuration ─────────────────────────────────────────────────────────────

SHANNON_DIR: Path = Path(os.environ.get("SHANNON_LOG_DIR",
    os.environ.get("FLEXAIDDS_LOG_DIR",
    str(Path.home() / ".shannon"))))
PETS_DIR: Path    = SHANNON_DIR / "pets"
DB_PATH:  Path    = SHANNON_DIR / "agent_hub.db"

ALL_AGENTS = [
    "claude_code", "cowork", "dispatch", "science",
    "grok_build", "codex", "dataset_runner",
]

# ── Pet state dataclass ───────────────────────────────────────────────────────

@dataclass
class PetState:
    status:        str            = "idle"         # "active" | "idle" | "mid_task"
    last_task:     str            = ""
    last_cf_delta: Optional[float] = None
    memory_size:   int            = 0
    history_count: int            = 0
    updated_at:    float          = 0.0            # unix timestamp
    resumable:     bool           = False

    def to_json(self) -> str:
        d = asdict(self)
        return json.dumps(d, indent=2)

    @classmethod
    def from_file(cls, path: Path) -> "PetState":
        try:
            raw = json.loads(path.read_text())
            return cls(**{k: v for k, v in raw.items() if k in cls.__dataclass_fields__})
        except Exception:
            return cls()


# ── PetManager ────────────────────────────────────────────────────────────────

class PetManager:
    """
    Read/write interface to ~/.shannon/pets/.
    Thread-safe at the file level (atomic writes via .tmp rename).
    """

    def __init__(self, pets_dir: Path = PETS_DIR, db_path: Path = DB_PATH) -> None:
        self.pets_dir = pets_dir
        self.db_path  = db_path
        self._ensure_dirs()

    # ── Directory bootstrap ────────────────────────────────────────────────

    def _ensure_dirs(self) -> None:
        for agent_id in ALL_AGENTS:
            self.ensure_pet(agent_id)

    def ensure_pet(self, agent_id: str) -> None:
        d = self.pets_dir / agent_id
        d.mkdir(parents=True, exist_ok=True)

        for fname in ("memory.md", "history.jsonl"):
            f = d / fname
            if not f.exists():
                f.touch()

        cfg = d / "config.json"
        if not cfg.exists():
            cfg.write_text(json.dumps({
                "voice_enabled": True,
                "notify_threshold": 3.5,
                "memory_limit_kb": 256,
            }, indent=2))

        state_f = d / "state.json"
        if not state_f.exists():
            self._write_state(agent_id, PetState())

    # ── State I/O ─────────────────────────────────────────────────────────

    def read_state(self, agent_id: str) -> PetState:
        path = self.pets_dir / agent_id / "state.json"
        return PetState.from_file(path)

    def write_state(self, agent_id: str, state: PetState) -> None:
        state.updated_at = time.time()
        state.memory_size   = self._memory_size(agent_id)
        state.history_count = self._history_count(agent_id)
        self._write_state(agent_id, state)

    def _write_state(self, agent_id: str, state: PetState) -> None:
        path = self.pets_dir / agent_id / "state.json"
        tmp  = path.with_suffix(".json.tmp")
        tmp.write_text(state.to_json())
        tmp.replace(path)       # atomic rename

    # ── Memory ────────────────────────────────────────────────────────────

    def read_memory(self, agent_id: str, max_bytes: int = 0) -> str:
        path = self.pets_dir / agent_id / "memory.md"
        if not path.exists():
            return ""
        text = path.read_text(encoding="utf-8")
        return text[:max_bytes] if max_bytes else text

    def append_memory(self, agent_id: str, text: str) -> None:
        path = self.pets_dir / agent_id / "memory.md"
        with path.open("a", encoding="utf-8") as f:
            f.write(f"\n{text}")

    def _memory_size(self, agent_id: str) -> int:
        p = self.pets_dir / agent_id / "memory.md"
        return p.stat().st_size if p.exists() else 0

    # ── History ───────────────────────────────────────────────────────────

    def append_history(self, agent_id: str, record: dict) -> None:
        path = self.pets_dir / agent_id / "history.jsonl"
        record.setdefault("ts", time.time())
        with path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record) + "\n")

    def recent_history(self, agent_id: str, n: int = 10) -> list[dict]:
        path = self.pets_dir / agent_id / "history.jsonl"
        if not path.exists():
            return []
        lines = [l for l in path.read_text(encoding="utf-8").splitlines() if l.strip()]
        result = []
        for line in lines[-n:]:
            try:
                result.append(json.loads(line))
            except json.JSONDecodeError:
                pass
        return result

    def _history_count(self, agent_id: str) -> int:
        p = self.pets_dir / agent_id / "history.jsonl"
        if not p.exists():
            return 0
        return sum(1 for l in p.read_text(encoding="utf-8").splitlines() if l.strip())

    # ── D_agents divergence check  ────────────────────────────────────────

    def check_divergence(self, agent_id: str, claimed_cf: float,
                          threshold: float = 20.0) -> Optional[str]:
        """
        Read agent's memory.md for past CF values.
        If a line contains "CF" followed by a number and the delta vs
        claimed_cf exceeds `threshold`, return a warning string.
        Logs a 'pet_memory_access' event to agent_activity in the DB.
        """
        memory = self.read_memory(agent_id)
        if not memory:
            return None

        self._log_memory_access(agent_id)

        import re
        # Match patterns like "CF=−187.3" or "CF: -187" or "CF −187.3"
        matches = re.findall(r"CF[\s=:]+([−\-]?\d+(?:\.\d+)?)", memory)
        if not matches:
            return None

        past_values = []
        for m in matches:
            try:
                past_values.append(float(m.replace("−", "-")))
            except ValueError:
                pass
        if not past_values:
            return None

        baseline = sum(past_values) / len(past_values)
        delta    = abs(claimed_cf - baseline)
        if delta > threshold:
            return (f"D_agents divergence for {agent_id}: "
                    f"memory baseline CF={baseline:.1f}, "
                    f"current report CF={claimed_cf:.1f}, "
                    f"delta={delta:.1f} > {threshold}")
        return None

    def _log_memory_access(self, agent_id: str) -> None:
        """Log 'pet_memory_access' to agent_activity so the Swift HUD animates the dot."""
        try:
            con = sqlite3.connect(str(self.db_path))
            con.execute("""
                INSERT OR IGNORE INTO agent_activity (event_type, agent_id, payload, timestamp)
                VALUES ('pet_memory_access', ?, 'memory read for D_agents', ?)
            """, (agent_id, time.time()))
            con.commit()
            con.close()
        except Exception:
            pass   # DB may not exist yet during early startup


# ── Convenience helpers for shannon_gate.py ───────────────────────────────────

_default_manager: Optional[PetManager] = None

def get_manager() -> PetManager:
    global _default_manager
    if _default_manager is None:
        _default_manager = PetManager()
    return _default_manager


def on_agent_turn_start(agent_id: str, task_summary: str) -> None:
    pm = get_manager()
    state = pm.read_state(agent_id)
    state.status    = "active"
    state.last_task = task_summary
    state.resumable = True
    pm.write_state(agent_id, state)
    pm.append_history(agent_id, {"event": "turn_start", "task": task_summary})


def on_agent_turn_end(agent_id: str, outcome: str,
                       cf: Optional[float] = None, entropy: Optional[float] = None) -> None:
    pm = get_manager()
    state = pm.read_state(agent_id)
    state.status    = "idle"
    state.resumable = False
    if cf is not None:
        state.last_cf_delta = cf
    pm.write_state(agent_id, state)
    pm.append_history(agent_id, {
        "event":   "turn_end",
        "outcome": outcome,
        "cf":      cf,
        "entropy": entropy,
    })


def check_pet_divergence(agent_id: str, claimed_cf: float) -> Optional[str]:
    return get_manager().check_divergence(agent_id, claimed_cf)


# ── CLI ───────────────────────────────────────────────────────────────────────

def _cli_main() -> None:
    ap = argparse.ArgumentParser(description="Shannon pet manager CLI")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="List all agents and their pet status")

    s = sub.add_parser("status", help="Show pet status for an agent")
    s.add_argument("agent_id", choices=ALL_AGENTS)

    st = sub.add_parser("set-task", help="Mark agent as active with a task")
    st.add_argument("agent_id", choices=ALL_AGENTS)
    st.add_argument("task")

    mi = sub.add_parser("mark-idle", help="Mark agent as idle / not resumable")
    mi.add_argument("agent_id", choices=ALL_AGENTS)

    lh = sub.add_parser("log-history", help="Append a JSON line to history.jsonl")
    lh.add_argument("agent_id", choices=ALL_AGENTS)
    lh.add_argument("record", help="JSON string")

    rm = sub.add_parser("read-memory", help="Print memory.md (optionally truncated)")
    rm.add_argument("agent_id", choices=ALL_AGENTS)
    rm.add_argument("--bytes", type=int, default=0)

    rs = sub.add_parser("reset", help="Reset pet state to idle defaults")
    rs.add_argument("agent_id", choices=ALL_AGENTS)

    args = ap.parse_args()
    pm   = PetManager()

    if args.cmd == "list":
        for aid in ALL_AGENTS:
            s = pm.read_state(aid)
            print(f"  {aid:16}  {s.status:10}  resumable={s.resumable}  "
                  f"mem={s.memory_size}B  hist={s.history_count}")

    elif args.cmd == "status":
        s = pm.read_state(args.agent_id)
        print(s.to_json())

    elif args.cmd == "set-task":
        on_agent_turn_start(args.agent_id, args.task)
        print(f"✅  {args.agent_id} → active: {args.task!r}")

    elif args.cmd == "mark-idle":
        on_agent_turn_end(args.agent_id, "manual_idle")
        print(f"✅  {args.agent_id} → idle")

    elif args.cmd == "log-history":
        try:
            record = json.loads(args.record)
        except json.JSONDecodeError as exc:
            print(f"❌  Invalid JSON: {exc}", file=sys.stderr)
            sys.exit(1)
        pm.append_history(args.agent_id, record)
        print(f"✅  Logged to {args.agent_id}/history.jsonl")

    elif args.cmd == "read-memory":
        text = pm.read_memory(args.agent_id, max_bytes=args.bytes)
        print(text or "(empty)")

    elif args.cmd == "reset":
        pm.write_state(args.agent_id, PetState())
        print(f"✅  {args.agent_id} pet state reset to idle defaults.")


if __name__ == "__main__":
    _cli_main()
