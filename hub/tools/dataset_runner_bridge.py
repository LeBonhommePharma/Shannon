#!/usr/bin/env python3
"""
tools/dataset_runner_bridge.py — FlexAIDdS ↔ Shannon Hub Adapter
==================================================================
Thin adapter between FlexAIDdS DatasetRunner result files and Shannon hub
``benchmark_state``.  Lives under Shannon ``hub/tools/`` so campaign churn is
testable without a sibling FlexAIDdS checkout.

Responsibilities
----------------
  1. Watch (or one-shot ingest) FlexAIDdS output directories for docking results.
  2. Package each result into a gate-compatible ``benchmark_state`` row:
         task_id        TEXT     — campaign / owner task id
         completed      INTEGER  — % of dataset complete (0–100; hub UI bar)
         total          INTEGER  — dataset size estimate
         best_cf        REAL     — best CF seen so far (column + state_json)
         best_rmsd      REAL
         active_target  TEXT
         state_json     TEXT     — domain-specific blob (cf/rmsd/target/…)
     The hub UI reads ``completed`` + ``state_json``; it does not require CF/RMSD
     as first-class hub columns, but gate migrations keep them for AuditDB.
  3. Write rows to agent_hub.db via direct SQLite insert (gate may be offline).

state_json schema (FlexAIDdS-specific, hub doesn't care about the keys)
------------------------------------------------------------------------
  {
    "cf":          -187.3,
    "best_cf":     -187.3,
    "rmsd":        1.14,
    "best_rmsd":   1.14,
    "target":      "1SG0",
    "pose_file":   "results/1SG0_pose1.pdb",
    "total":       85,
    "done":        42,
    "completed":   49,           // same as row.completed (0–100)
    "run_id":      "run_20260722_143012",
    "agent_id":    "dataset_runner"
  }

Environment variables
---------------------
  SHANNON_LOG_DIR      — path to ~/.shannon (default)
  FLEXAIDDS_LOG_DIR    — backward-compat alias
  FLEXAIDDS_RESULTS    — root directory to watch for .result files

Usage
-----
  # Long-running watch
  python tools/dataset_runner_bridge.py --results-dir ./results \\
      --agent-id dataset_runner --task flexaidds_astex_…

  # One-shot fixture / batch churn (no infinite loop)
  python tools/dataset_runner_bridge.py --results-dir ./results --once
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any, Optional

# ── Configuration ─────────────────────────────────────────────────────────────

SHANNON_LOG_DIR: Path = Path(
    os.environ.get(
        "SHANNON_LOG_DIR",
        os.environ.get("FLEXAIDDS_LOG_DIR", str(Path.home() / ".shannon")),
    )
)
DB_PATH: Path = SHANNON_LOG_DIR / "agent_hub.db"
SOCKET_PATH: str = "/tmp/shannon.sock"

DEFAULT_RESULTS_DIR: Path = Path(os.environ.get("FLEXAIDDS_RESULTS", "./results"))
DEFAULT_AGENT_ID = "dataset_runner"
DEFAULT_TOTAL = 85  # classic FlexAIDdS Astex-style size when no manifest
WATCH_INTERVAL = 2.0  # seconds


# ── DB helpers (gate-compatible schema) ───────────────────────────────────────


def _open_db(path: Path) -> sqlite3.Connection:
    """Open agent_hub.db and ensure gate-compatible benchmark_state exists.

    Creates a schema the hub UI / gate can read:
      task_id, completed, total, best_cf, best_rmsd, active_target, state_json

    Also tolerates a legacy bridge-only schema (agent_id/progress) by migrating
    additive columns when possible so churn still lands in a readable form.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), check_same_thread=False)
    con.execute("PRAGMA journal_mode=WAL;")

    con.execute(
        """
        CREATE TABLE IF NOT EXISTS benchmark_state (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            updated_at    INTEGER NOT NULL,
            task_id       TEXT NOT NULL,
            completed     INTEGER DEFAULT 0,
            total         INTEGER DEFAULT 85,
            best_cf       REAL,
            best_rmsd     REAL,
            active_target TEXT,
            state_json    TEXT NOT NULL DEFAULT '{}'
        );
        """
    )
    cols = {row[1] for row in con.execute("PRAGMA table_info(benchmark_state)")}
    # Migrate legacy bridge schema → gate columns when present.
    if "progress" in cols and "completed" not in cols:
        try:
            con.execute(
                "ALTER TABLE benchmark_state RENAME COLUMN progress TO completed"
            )
            cols.discard("progress")
            cols.add("completed")
        except sqlite3.OperationalError:
            pass
    for col_name, col_def in (
        ("completed", "INTEGER DEFAULT 0"),
        ("total", "INTEGER DEFAULT 85"),
        ("best_cf", "REAL"),
        ("best_rmsd", "REAL"),
        ("active_target", "TEXT"),
        ("state_json", "TEXT NOT NULL DEFAULT '{}'"),
        ("task_id", "TEXT"),
        ("updated_at", "INTEGER"),
        ("agent_id", "TEXT"),  # optional convenience; UI keys via task_id join
    ):
        if col_name not in cols:
            try:
                con.execute(
                    f"ALTER TABLE benchmark_state ADD COLUMN {col_name} {col_def}"
                )
            except sqlite3.OperationalError:
                pass

    con.execute(
        """
        CREATE TABLE IF NOT EXISTS agent_activity (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            agent_id     TEXT NOT NULL,
            event_at_ns  INTEGER NOT NULL,
            event_type   TEXT NOT NULL,
            event_label  TEXT NOT NULL,
            event_output TEXT,
            tool_kind    TEXT
        );
        """
    )
    act_cols = {row[1] for row in con.execute("PRAGMA table_info(agent_activity)")}
    # Legacy bridge wrote payload/timestamp — add gate columns if missing.
    for col_name, col_def in (
        ("event_at_ns", "INTEGER"),
        ("event_label", "TEXT"),
        ("event_output", "TEXT"),
        ("tool_kind", "TEXT"),
        ("payload", "TEXT"),  # keep if already there; unused by new writers
        ("timestamp", "REAL"),
    ):
        if col_name not in act_cols:
            try:
                con.execute(
                    f"ALTER TABLE agent_activity ADD COLUMN {col_name} {col_def}"
                )
            except sqlite3.OperationalError:
                pass

    con.commit()
    return con


def _upsert_benchmark(
    con: sqlite3.Connection,
    agent_id: str,
    progress: int,
    state: dict[str, Any],
    *,
    task_id: Optional[str] = None,
    total: Optional[int] = None,
) -> None:
    """Insert a new benchmark_state row (append-only, gate-compatible).

    ``progress`` is 0–100 (hub ProgressView denominator). Domain metrics live in
    ``state`` and are mirrored onto best_cf/best_rmsd/active_target columns when
    present. Never invents CF/RMSD — only copies keys from ``state``.
    """
    tid = task_id or state.get("task_id") or agent_id
    tot = int(total if total is not None else state.get("total") or DEFAULT_TOTAL)
    completed = max(0, min(int(progress), 100))
    best_cf = state.get("best_cf", state.get("cf"))
    best_rmsd = state.get("best_rmsd", state.get("rmsd"))
    active = state.get("active_target") or state.get("target")

    blob = dict(state)
    blob.setdefault("agent_id", agent_id)
    blob.setdefault("task_id", tid)
    blob["completed"] = completed
    blob["total"] = tot
    if best_cf is not None:
        blob.setdefault("cf", best_cf)
        blob.setdefault("best_cf", best_cf)
    if best_rmsd is not None:
        blob.setdefault("rmsd", best_rmsd)
        blob.setdefault("best_rmsd", best_rmsd)
    if active:
        blob.setdefault("target", active)
        blob.setdefault("active_target", active)

    now_ns = time.time_ns()
    cols = {row[1] for row in con.execute("PRAGMA table_info(benchmark_state)")}

    if "task_id" in cols and "completed" in cols:
        # Gate schema path (preferred).
        insert_cols = [
            "updated_at",
            "task_id",
            "completed",
            "total",
            "best_cf",
            "best_rmsd",
            "active_target",
            "state_json",
        ]
        values: list[Any] = [
            now_ns,
            tid,
            completed,
            tot,
            best_cf if isinstance(best_cf, (int, float)) else None,
            best_rmsd if isinstance(best_rmsd, (int, float)) else None,
            active,
            json.dumps(blob),
        ]
        if "agent_id" in cols:
            insert_cols.append("agent_id")
            values.append(agent_id)
        placeholders = ", ".join("?" * len(insert_cols))
        con.execute(
            f"INSERT INTO benchmark_state ({', '.join(insert_cols)}) "
            f"VALUES ({placeholders})",
            values,
        )
    else:
        # Extreme fallback: agent_id PK + progress (legacy only).
        con.execute(
            """
            INSERT INTO benchmark_state (agent_id, progress, state_json, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(agent_id) DO UPDATE SET
                progress   = excluded.progress,
                state_json = excluded.state_json,
                updated_at = excluded.updated_at;
            """,
            (agent_id, completed, json.dumps(blob), time.time()),
        )

    # Activity feed (gate columns preferred).
    act_cols = {row[1] for row in con.execute("PRAGMA table_info(agent_activity)")}
    summary = (
        f"target={active or '?'}  CF={best_cf if best_cf is not None else '?'}  "
        f"RMSD={best_rmsd if best_rmsd is not None else '?'}  {completed}%"
    )
    if "event_label" in act_cols and "event_at_ns" in act_cols:
        con.execute(
            """
            INSERT INTO agent_activity
                (agent_id, event_at_ns, event_type, event_label, event_output, tool_kind)
            VALUES (?, ?, 'tool_call', ?, ?, 'other');
            """,
            (agent_id, now_ns, f"Dock({active or '?'})", summary),
        )
    else:
        con.execute(
            """
            INSERT INTO agent_activity (event_type, agent_id, payload, timestamp)
            VALUES ('tool_call', ?, ?, ?);
            """,
            (agent_id, summary, time.time()),
        )
    con.commit()


# ── Result file parsers ───────────────────────────────────────────────────────


def _normalize_result_keys(result: dict[str, Any], path: Optional[Path] = None) -> dict[str, Any]:
    """Normalise well-known CF/RMSD aliases; never invent numeric science values."""
    for alias_cf in ("cf_score", "interaction_energy", "score"):
        if alias_cf in result and "cf" not in result:
            result["cf"] = result[alias_cf]
    if "cf" in result and "best_cf" not in result:
        result["best_cf"] = result["cf"]
    if "best_cf" in result and "cf" not in result:
        result["cf"] = result["best_cf"]

    for alias_rmsd in ("rmsd_to_ref", "rmsd_ref"):
        if alias_rmsd in result and "rmsd" not in result:
            result["rmsd"] = result[alias_rmsd]
    if "rmsd" in result and "best_rmsd" not in result:
        result["best_rmsd"] = result["rmsd"]
    if "best_rmsd" in result and "rmsd" not in result:
        result["rmsd"] = result["best_rmsd"]

    if "target" not in result and path is not None:
        m = re.match(r"([A-Z0-9]{4})", path.stem.upper())
        if m:
            result["target"] = m.group(1)

    if path is not None and "pose_file" not in result:
        result["pose_file"] = str(path)
    return result


def _parse_result_file(path: Path) -> Optional[dict[str, Any]]:
    """
    Parse a FlexAIDdS .result or .json file into a state_json dict.
    Accepts two formats:
      - JSON files: direct key→value (aliases normalised)
      - Text files: key: value lines (FlexAIDdS legacy format)
    """
    text = path.read_text(encoding="utf-8", errors="replace")

    # Try JSON first
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return _normalize_result_keys(dict(obj), path)
    except json.JSONDecodeError:
        pass

    # Text parse
    result: dict[str, Any] = {}
    for line in text.splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip().lower().replace(" ", "_")
        val = val.strip()
        try:
            result[key] = float(val)
        except ValueError:
            result[key] = val

    if not result:
        return None
    return _normalize_result_keys(result, path)


def _scan_results(results_dir: Path) -> list[Path]:
    """Return result files sorted by mtime (oldest first — churn order)."""
    patterns = ("*.result", "*.json", "*.out")
    files: list[Path] = []
    for pat in patterns:
        files.extend(results_dir.glob(pat))
    return sorted(set(files), key=lambda p: p.stat().st_mtime)


def _cf_of(result: dict[str, Any]) -> Optional[float]:
    cf = result.get("cf", result.get("best_cf"))
    return float(cf) if isinstance(cf, (int, float)) else None


# ── Watcher / one-shot ingest ─────────────────────────────────────────────────


class DatasetRunnerWatcher:
    """Ingest FlexAIDdS result files into hub ``benchmark_state`` with progress churn.

    Each new result advances ``done`` / ``completed`` (0–100). Global best CF is
    tracked across the whole run, not just the latest batch.
    """

    def __init__(
        self,
        results_dir: Path,
        agent_id: str,
        db_path: Path,
        watch_interval: float = WATCH_INTERVAL,
        *,
        task_id: Optional[str] = None,
        total: Optional[int] = None,
        quiet: bool = False,
    ) -> None:
        self.results_dir = results_dir
        self.agent_id = agent_id
        self.db_path = db_path
        self.watch_interval = watch_interval
        self.task_id = task_id or agent_id
        self.quiet = quiet
        self._seen: set[Path] = set()
        self._total: int = int(total) if total is not None else 0
        self._best_cf: float = float("inf")
        self._best_result: Optional[dict[str, Any]] = None
        self._con: Optional[sqlite3.Connection] = None
        self._ticks: int = 0
        self._last_progress: int = 0

    def _db(self) -> sqlite3.Connection:
        if self._con is None:
            self._con = _open_db(self.db_path)
        return self._con

    def close(self) -> None:
        if self._con is not None:
            self._con.close()
            self._con = None

    def _ensure_total(self, file_count: int) -> None:
        if self._total:
            return
        manifest = self.results_dir.parent / "dataset.txt"
        if not manifest.exists():
            # Also accept results_dir/dataset.txt
            manifest = self.results_dir / "dataset.txt"
        if manifest.exists():
            self._total = sum(1 for line in manifest.read_text().splitlines() if line.strip())
        else:
            self._total = max(file_count + 10, DEFAULT_TOTAL)

    def run(self) -> None:
        print(
            f"[bridge] watching {self.results_dir}  agent={self.agent_id}  "
            f"task={self.task_id}",
            flush=True,
        )
        while True:
            try:
                self._tick()
            except Exception as exc:
                print(f"[bridge] tick error: {exc}", file=sys.stderr)
            time.sleep(self.watch_interval)

    def ingest_once(self) -> dict[str, Any]:
        """Process all current result files once (fixture / batch churn).

        Returns a summary: {done, total, progress, best_cf, best_rmsd, target, ticks}.
        """
        # Drain in one or more ticks until no new files remain.
        while True:
            n_before = len(self._seen)
            self._tick()
            if len(self._seen) == n_before:
                break
        return {
            "done": len(self._seen),
            "total": self._total or DEFAULT_TOTAL,
            "progress": self._last_progress,
            "best_cf": (
                self._best_cf if self._best_cf != float("inf") else None
            ),
            "best_rmsd": (
                self._best_result.get("rmsd") if self._best_result else None
            ),
            "target": (
                self._best_result.get("target") if self._best_result else None
            ),
            "ticks": self._ticks,
            "task_id": self.task_id,
            "agent_id": self.agent_id,
            "ok": True,
        }

    def _tick(self) -> Optional[dict[str, Any]]:
        if not self.results_dir.exists():
            return None

        files = _scan_results(self.results_dir)
        self._ensure_total(len(files))

        new_files = [f for f in files if f not in self._seen]
        if not new_files:
            return None

        batch_updated = False
        for f in new_files:
            r = _parse_result_file(f)
            self._seen.add(f)
            if r is None:
                continue
            cf = _cf_of(r)
            if cf is not None and cf < self._best_cf:
                self._best_cf = cf
                self._best_result = dict(r)
            elif self._best_result is None:
                # No CF yet — still record latest as state for progress churn.
                self._best_result = dict(r)
            batch_updated = True

        if not batch_updated and self._best_result is None:
            return None

        done = len(self._seen)
        progress = min(int(done / max(self._total, 1) * 100), 100)
        self._last_progress = progress
        self._ticks += 1

        state = dict(self._best_result or {})
        state.update(
            {
                "total": self._total,
                "done": done,
                "completed": progress,
                "run_id": f"run_{time.strftime('%Y%m%d_%H%M%S')}",
                "task_id": self.task_id,
                "agent_id": self.agent_id,
            }
        )
        if self._best_cf != float("inf"):
            state["cf"] = self._best_cf
            state["best_cf"] = self._best_cf

        _upsert_benchmark(
            self._db(),
            self.agent_id,
            progress,
            state,
            task_id=self.task_id,
            total=self._total,
        )
        if not self.quiet:
            cf_str = f"{self._best_cf:.1f}" if self._best_cf != float("inf") else "?"
            rmsd_str = f"{state.get('rmsd', '?')}"
            print(
                f"[bridge] +{len(new_files)} files  progress={progress}%  "
                f"done={done}/{self._total}  bestCF={cf_str}  RMSD={rmsd_str}",
                flush=True,
            )
        return state


def ingest_results(
    results_dir: Path,
    *,
    agent_id: str = DEFAULT_AGENT_ID,
    db_path: Optional[Path] = None,
    task_id: Optional[str] = None,
    total: Optional[int] = None,
) -> dict[str, Any]:
    """Public one-shot helper: ingest all results under ``results_dir`` once."""
    watcher = DatasetRunnerWatcher(
        results_dir=results_dir,
        agent_id=agent_id,
        db_path=db_path or DB_PATH,
        task_id=task_id,
        total=total,
    )
    try:
        return watcher.ingest_once()
    finally:
        watcher.close()


# ── CLI ───────────────────────────────────────────────────────────────────────


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        description="FlexAIDdS ↔ Shannon Hub bridge (thin adapter)"
    )
    ap.add_argument(
        "--results-dir",
        default=str(DEFAULT_RESULTS_DIR),
        help="Directory containing .result/.json output files",
    )
    ap.add_argument(
        "--agent-id",
        default=DEFAULT_AGENT_ID,
        help="Agent ID to post updates under (default: dataset_runner)",
    )
    ap.add_argument(
        "--task",
        default=None,
        help="Campaign task_id for benchmark_state (default: agent-id)",
    )
    ap.add_argument("--db", default=str(DB_PATH), help="Path to agent_hub.db")
    ap.add_argument(
        "--interval",
        default=WATCH_INTERVAL,
        type=float,
        help="Watch interval in seconds (default 2)",
    )
    ap.add_argument(
        "--total",
        default=None,
        type=int,
        help="Dataset size (default: manifest or 85)",
    )
    ap.add_argument(
        "--once",
        action="store_true",
        help="One-shot ingest of current results then exit (fixture churn)",
    )
    ap.add_argument(
        "--json",
        action="store_true",
        help="With --once, print ingest summary as JSON",
    )
    args = ap.parse_args(argv)

    watcher = DatasetRunnerWatcher(
        results_dir=Path(args.results_dir),
        agent_id=args.agent_id,
        db_path=Path(args.db),
        watch_interval=args.interval,
        task_id=args.task,
        total=args.total,
        quiet=bool(args.json),  # pure JSON on stdout when --json
    )
    try:
        if args.once:
            summary = watcher.ingest_once()
            if args.json:
                print(json.dumps(summary, indent=2, default=str))
            else:
                print(
                    f"[bridge] ingest done={summary['done']}/{summary['total']}  "
                    f"progress={summary['progress']}%  bestCF={summary['best_cf']}",
                    flush=True,
                )
            return 0
        watcher.run()
        return 0
    except KeyboardInterrupt:
        print("\n[bridge] stopped.")
        return 0
    finally:
        watcher.close()


if __name__ == "__main__":
    raise SystemExit(main())
