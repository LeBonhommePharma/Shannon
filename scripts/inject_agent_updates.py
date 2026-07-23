#!/usr/bin/env python3
"""Inject synthetic status + one approval ask through the live Shannon gate.

Usage (gate must be running):
  python3 scripts/inject_agent_updates.py
  python3 scripts/inject_agent_updates.py --ask-only
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "hub"))

from agent_identity import CORE_AGENT_IDS, label_for  # noqa: E402
from agent_protocol import AgentClient, SOCKET_PATH  # noqa: E402


def dump_db(db_path: Path) -> dict:
    if not db_path.exists():
        return {"error": "no db"}
    conn = sqlite3.connect(str(db_path))
    agents = conn.execute(
        "SELECT agent_id, status, task_summary, entropy_score FROM agents ORDER BY agent_id"
    ).fetchall()
    acts = conn.execute(
        "SELECT agent_id, event_type, event_label FROM agent_activity "
        "ORDER BY rowid DESC LIMIT 20"
    ).fetchall()
    pending = []
    try:
        pending = conn.execute(
            "SELECT interaction_id, agent_id, prompt, status FROM agent_interactions "
            "WHERE status='pending'"
        ).fetchall()
    except sqlite3.OperationalError:
        pass
    conn.close()
    return {
        "agents": [
            {"agent_id": a[0], "status": a[1], "task_summary": a[2], "entropy": a[3]}
            for a in agents
        ],
        "activity": [
            {"agent_id": a[0], "event_type": a[1], "event_label": a[2]} for a in acts
        ],
        "pending": [
            {
                "interaction_id": p[0],
                "agent_id": p[1],
                "prompt": p[2],
                "status": p[3],
            }
            for p in pending
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ask-only", action="store_true")
    ap.add_argument(
        "--db",
        default=str(Path.home() / ".shannon" / "agent_hub.db"),
    )
    args = ap.parse_args()

    if not os.path.exists(SOCKET_PATH):
        print(f"FAIL: gate socket missing at {SOCKET_PATH}", file=sys.stderr)
        print("Start with: ./scripts/shannon gate", file=sys.stderr)
        return 2

    sample = [
        "grok_build",
        "codex",
        "science",
        "claude_code",
        "dispatch",
        "cowork",
    ]
    results = []
    if not args.ask_only:
        for aid in sample:
            with AgentClient(aid, task_id="inject_demo", mode="socket") as c:
                r = c.send_status(
                    f"{label_for(aid)}: demo status at {time.strftime('%H:%M:%S')}",
                    details={"step": 1, "source": "inject_agent_updates"},
                )
                results.append({"agent_id": aid, "gate": r})
                print(f"status {aid}: {r.get('decision')} H={r.get('gate_H')}")

    # One full ask from science
    with AgentClient("science", task_id="inject_demo", mode="socket") as c:
        r = c.send_approval_needed(
            "Apply Softβ canary config for Astex Arm A?",
            interaction_id=f"inject-ask-science-{int(time.time())}",
        )
        results.append({"agent_id": "science", "ask_gate": r})
        print(f"ask science: {r.get('decision')} {r}")

    dump = dump_db(Path(args.db))
    print(json.dumps({"results": results, "db": dump}, indent=2))
    # Basic success criteria
    agent_ids = {a["agent_id"] for a in dump.get("agents", [])}
    if not args.ask_only:
        missing = set(sample) - agent_ids
        if missing:
            print(f"WARN: agents not in DB yet: {missing}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
