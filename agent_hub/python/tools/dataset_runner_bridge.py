#!/usr/bin/env python3
"""
tools/dataset_runner_bridge.py — FlexAIDdS ↔ Shannon Hub Adapter
==================================================================
STAYS IN THE FlexAIDdS REPO.  The Shannon hub knows nothing about FlexAIDdS
internals; this thin adapter is the only layer that does.

Responsibilities
----------------
  1. Watch FlexAIDdS output directories for new docking results.
  2. Package each result into a generic BenchmarkState row:
         progress  INTEGER   — % of dataset complete
         state_json TEXT     — JSON with domain-specific fields
     The hub only reads "progress" + arbitrary JSON — no CF/RMSD columns.
  3. Write rows to agent_hub.db via the Shannon socket OR direct SQLite insert.

state_json schema (FlexAIDdS-specific, hub doesn't care about the keys)
------------------------------------------------------------------------
  {
    "cf":          -187.3,       // best interaction energy (CF score)
    "best_cf":     -187.3,       // alias — AuditDBReader checks both
    "rmsd":        1.14,         // best pose RMSD vs reference
    "best_rmsd":   1.14,
    "target":      "1SG0",
    "pose_file":   "results/1SG0_pose1.pdb",
    "total":       85,           // total dataset entries
    "done":        42,
    "run_id":      "run_20260722_143012"
  }

Environment variables
---------------------
  SHANNON_LOG_DIR      — path to ~/.shannon (default)
  FLEXAIDDS_LOG_DIR    — backward-compat alias
  FLEXAIDDS_RESULTS    — root directory to watch for .result files

Usage
-----
  python tools/dataset_runner_bridge.py [--results-dir ./results] [--agent-id dataset_runner]
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
from typing import Optional

# ── Configuration ─────────────────────────────────────────────────────────────

SHANNON_LOG_DIR: Path = Path(os.environ.get("SHANNON_LOG_DIR",
    os.environ.get("FLEXAIDDS_LOG_DIR",
    str(Path.home() / ".shannon"))))
DB_PATH:          Path = SHANNON_LOG_DIR / "agent_hub.db"
SOCKET_PATH:      str  = "/tmp/shannon.sock"

DEFAULT_RESULTS_DIR: Path = Path(
    os.environ.get("FLEXAIDDS_RESULTS", "./results")
)
DEFAULT_AGENT_ID    = "dataset_runner"
WATCH_INTERVAL      = 2.0   # seconds


# ── DB helpers ────────────────────────────────────────────────────────────────

def _open_db(path: Path) -> sqlite3.Connection:
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(path), check_same_thread=False)
    con.execute("PRAGMA journal_mode=WAL;")
    # Ensure table exists (gate may not be running yet)
    con.execute("""
        CREATE TABLE IF NOT EXISTS benchmark_state (
            agent_id  TEXT PRIMARY KEY,
            progress  INTEGER DEFAULT 0,
            state_json TEXT NOT NULL DEFAULT '{}',
            updated_at REAL
        );
    """)
    con.execute("""
        CREATE TABLE IF NOT EXISTS agent_activity (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            event_type TEXT NOT NULL,
            agent_id   TEXT NOT NULL,
            payload    TEXT DEFAULT '',
            timestamp  REAL NOT NULL
        );
    """)
    con.commit()
    return con


def _upsert_benchmark(con: sqlite3.Connection, agent_id: str,
                       progress: int, state: dict) -> None:
    con.execute("""
        INSERT INTO benchmark_state (agent_id, progress, state_json, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(agent_id) DO UPDATE SET
            progress   = excluded.progress,
            state_json = excluded.state_json,
            updated_at = excluded.updated_at;
    """, (agent_id, progress, json.dumps(state), time.time()))

    # Log activity event so the HUD feed picks it up
    summary = f"target={state.get('target','?')}  CF={state.get('cf','?')}  " \
              f"RMSD={state.get('rmsd','?')}  {progress}%"
    con.execute("""
        INSERT INTO agent_activity (event_type, agent_id, payload, timestamp)
        VALUES ('tool_call', ?, ?, ?);
    """, (agent_id, summary, time.time()))
    con.commit()


# ── Result file parsers ───────────────────────────────────────────────────────

def _parse_result_file(path: Path) -> Optional[dict]:
    """
    Parse a FlexAIDdS .result or .json file into a state_json dict.
    Accepts two formats:
      - JSON files: direct key→value
      - Text files: key: value lines (FlexAIDdS legacy format)
    """
    text = path.read_text(encoding="utf-8", errors="replace")

    # Try JSON first
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except json.JSONDecodeError:
        pass

    # Text parse
    result: dict = {}
    for line in text.splitlines():
        line = line.strip()
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip().lower().replace(" ", "_")
        val = val.strip()
        # Try numeric
        try:
            result[key] = float(val)
        except ValueError:
            result[key] = val

    # Normalise well-known keys
    for alias_cf in ("cf_score", "interaction_energy", "score"):
        if alias_cf in result and "cf" not in result:
            result["cf"] = result[alias_cf]
    if "cf" in result:
        result["best_cf"] = result["cf"]

    for alias_rmsd in ("rmsd_to_ref", "rmsd_ref"):
        if alias_rmsd in result and "rmsd" not in result:
            result["rmsd"] = result[alias_rmsd]
    if "rmsd" in result:
        result["best_rmsd"] = result["rmsd"]

    # Infer target from filename e.g. "1SG0_pose1.result"
    if "target" not in result:
        m = re.match(r"([A-Z0-9]{4})", path.stem.upper())
        if m:
            result["target"] = m.group(1)

    result["pose_file"] = str(path)
    return result or None


def _scan_results(results_dir: Path) -> list[Path]:
    """Return result files sorted by mtime (newest last)."""
    patterns = ("*.result", "*.json", "*.out")
    files: list[Path] = []
    for pat in patterns:
        files.extend(results_dir.glob(pat))
    return sorted(set(files), key=lambda p: p.stat().st_mtime)


# ── Watcher ───────────────────────────────────────────────────────────────────

class DatasetRunnerWatcher:
    def __init__(self,
                 results_dir: Path,
                 agent_id:    str,
                 db_path:     Path,
                 watch_interval: float = WATCH_INTERVAL) -> None:
        self.results_dir    = results_dir
        self.agent_id       = agent_id
        self.db_path        = db_path
        self.watch_interval = watch_interval
        self._seen:  set[Path]  = set()
        self._total: int        = 0
        self._con:   Optional[sqlite3.Connection] = None

    def _db(self) -> sqlite3.Connection:
        if self._con is None:
            self._con = _open_db(self.db_path)
        return self._con

    def run(self) -> None:
        print(f"[bridge] watching {self.results_dir}  agent={self.agent_id}",
              flush=True)
        while True:
            try:
                self._tick()
            except Exception as exc:
                print(f"[bridge] tick error: {exc}", file=sys.stderr)
            time.sleep(self.watch_interval)

    def _tick(self) -> None:
        if not self.results_dir.exists():
            return

        files = _scan_results(self.results_dir)
        if not self._total:
            # Estimate total from a manifest file if present
            manifest = self.results_dir.parent / "dataset.txt"
            if manifest.exists():
                self._total = sum(1 for l in manifest.read_text().splitlines() if l.strip())
            else:
                self._total = max(len(files) + 10, 85)   # default FlexAIDdS benchmark size

        new_files = [f for f in files if f not in self._seen]
        if not new_files:
            return

        # Take the best result from new files
        best_result: Optional[dict] = None
        best_cf     = float("inf")
        for f in new_files:
            r = _parse_result_file(f)
            if r is None:
                continue
            cf = r.get("cf") or r.get("best_cf")
            if isinstance(cf, (int, float)) and cf < best_cf:
                best_cf     = cf
                best_result = r
            self._seen.add(f)

        if best_result is None:
            for f in new_files:
                self._seen.add(f)
            return

        done     = len(self._seen)
        progress = min(int(done / max(self._total, 1) * 100), 100)

        best_result.update({
            "total":  self._total,
            "done":   done,
            "run_id": f"run_{time.strftime('%Y%m%d_%H%M%S')}",
        })

        _upsert_benchmark(self._db(), self.agent_id, progress, best_result)
        cf_str   = f"{best_cf:.1f}" if best_cf != float('inf') else "?"
        rmsd_str = f"{best_result.get('rmsd', '?')}"
        print(f"[bridge] +{len(new_files)} files  progress={progress}%  "
              f"bestCF={cf_str}  RMSD={rmsd_str}", flush=True)


# ── CLI ───────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ap = argparse.ArgumentParser(
        description="FlexAIDdS ↔ Shannon Hub bridge (thin adapter)")
    ap.add_argument("--results-dir", default=str(DEFAULT_RESULTS_DIR),
                    help="Directory containing .result/.json output files")
    ap.add_argument("--agent-id", default=DEFAULT_AGENT_ID,
                    help="Agent ID to post updates under (default: dataset_runner)")
    ap.add_argument("--db", default=str(DB_PATH),
                    help="Path to agent_hub.db")
    ap.add_argument("--interval", default=WATCH_INTERVAL, type=float,
                    help="Watch interval in seconds (default 2)")
    args = ap.parse_args()

    watcher = DatasetRunnerWatcher(
        results_dir=Path(args.results_dir),
        agent_id=args.agent_id,
        db_path=Path(args.db),
        watch_interval=args.interval,
    )
    try:
        watcher.run()
    except KeyboardInterrupt:
        print("\n[bridge] stopped.")
