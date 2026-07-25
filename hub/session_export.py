#!/usr/bin/env python3
"""
session_export.py — Read-only timeline export from the Shannon Gate audit DB.

Exports ``agent_activity`` and ``agent_interactions`` into a unified list of
event dicts suitable for JSONL / debugging / offline review.

Usage
-----
  from session_export import export_session_events, export_session_jsonl, write_jsonl

  events = export_session_events(Path("~/Library/.../agent_hub.db").expanduser())
  write_jsonl(Path("session.jsonl"), events)

  # CLI-style one-liner:
  # python -c "from session_export import export_session_jsonl; \\
  #            print(export_session_jsonl('agent_hub.db'))"
"""

from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any, Iterable, Optional, Union

__all__ = [
    "export_session_events",
    "export_session_jsonl",
    "write_jsonl",
]


def _open_readonly(db_path: Path) -> sqlite3.Connection:
    """Open SQLite in read-only mode (URI). Falls back to normal open if needed."""
    uri = f"file:{db_path.resolve()}?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True)
    except sqlite3.OperationalError:
        # DB missing / unreadable as URI — open normally for clearer errors later
        conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def _table_exists(conn: sqlite3.Connection, name: str) -> bool:
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1",
        (name,),
    ).fetchone()
    return row is not None


def export_session_events(
    db_path: Path | str,
    since_ns: int | None = None,
) -> list[dict[str, Any]]:
    """Read agent_activity + agent_interactions into a sorted timeline.

    Each event dict has keys:
      ts_ns    : int   — event timestamp (nanoseconds)
      agent_id : str
      kind     : str   — activity event_type, or 'interaction' / 'interaction_<status>'
      label    : str   — event_label or interaction prompt (truncated)
      detail   : str   — event_output or interaction status / full prompt

    Parameters
    ----------
    db_path :
        Path to the gate SQLite audit database.
    since_ns :
        If set, only include events with ts_ns >= since_ns.

    Returns
    -------
    list[dict]
        Chronological timeline (ascending ts_ns). Empty if tables are missing
        or the DB has no matching rows.
    """
    path = Path(db_path)
    if not path.exists():
        return []

    events: list[dict[str, Any]] = []
    with _open_readonly(path) as conn:
        if _table_exists(conn, "agent_activity"):
            sql = (
                "SELECT event_at_ns, agent_id, event_type, event_label, event_output "
                "FROM agent_activity"
            )
            params: list[Any] = []
            if since_ns is not None:
                sql += " WHERE event_at_ns >= ?"
                params.append(int(since_ns))
            for row in conn.execute(sql, params):
                events.append(
                    {
                        "ts_ns": int(row["event_at_ns"]),
                        "agent_id": str(row["agent_id"] or ""),
                        "kind": str(row["event_type"] or "activity"),
                        "label": str(row["event_label"] or ""),
                        "detail": str(row["event_output"] or ""),
                    }
                )

        if _table_exists(conn, "agent_interactions"):
            sql = (
                "SELECT interaction_id, agent_id, prompt, status, created_at_ns, "
                "resolved_at_ns FROM agent_interactions"
            )
            params = []
            if since_ns is not None:
                sql += " WHERE created_at_ns >= ?"
                params.append(int(since_ns))
            for row in conn.execute(sql, params):
                status = str(row["status"] or "pending")
                prompt = str(row["prompt"] or "")
                label = prompt if len(prompt) <= 120 else prompt[:117] + "..."
                events.append(
                    {
                        "ts_ns": int(row["created_at_ns"]),
                        "agent_id": str(row["agent_id"] or ""),
                        "kind": f"interaction_{status}",
                        "label": label,
                        "detail": prompt,
                    }
                )

    events.sort(key=lambda e: (e["ts_ns"], e["agent_id"], e["kind"]))
    return events


def export_session_jsonl(
    db_path: Path | str,
    since_ns: int | None = None,
) -> str:
    """Return newline-delimited JSON for all exported events."""
    events = export_session_events(db_path, since_ns=since_ns)
    return "\n".join(json.dumps(e, ensure_ascii=False) for e in events) + (
        "\n" if events else ""
    )


def write_jsonl(
    path: Path | str,
    events: Optional[Iterable[dict[str, Any]]] = None,
    *,
    db_path: Optional[Union[Path, str]] = None,
    since_ns: int | None = None,
) -> int:
    """Write events as JSONL. Returns number of lines written.

    Provide either ``events`` or ``db_path`` (which is exported first).
    """
    if events is None:
        if db_path is None:
            raise ValueError("write_jsonl requires events= or db_path=")
        events = export_session_events(db_path, since_ns=since_ns)
    out = Path(path)
    out.parent.mkdir(parents=True, exist_ok=True)
    n = 0
    with out.open("w", encoding="utf-8") as fh:
        for ev in events:
            fh.write(json.dumps(ev, ensure_ascii=False) + "\n")
            n += 1
    return n


if __name__ == "__main__":
    import argparse
    import sys

    p = argparse.ArgumentParser(description="Export Shannon Gate session timeline")
    p.add_argument("db_path", type=Path, help="Path to agent_hub.db")
    p.add_argument("-o", "--output", type=Path, default=None, help="Write JSONL here")
    p.add_argument("--since-ns", type=int, default=None)
    args = p.parse_args()

    if args.output is not None:
        n = write_jsonl(args.output, db_path=args.db_path, since_ns=args.since_ns)
        print(f"Wrote {n} events to {args.output}", file=sys.stderr)
    else:
        sys.stdout.write(export_session_jsonl(args.db_path, since_ns=args.since_ns))
