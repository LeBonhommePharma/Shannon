#!/usr/bin/env python3
"""
shannon_gate.py — FlexAIDdS Agent Hub Shannon Gate Daemon
==========================================================
Central message broker and entropy guardian for the multi-agent FlexAIDdS
collaboration system. Receives outputs from Codex, Claude Cowork/Dispatch/Science,
and Grok Build; computes Shannon entropy to guard against hallucinated or
adversarial agent contributions; routes validated messages between agents;
maintains a full SQLite audit log.

Architecture
------------
  Cloud agents (Codex, Claude, Grok) ──HTTPS POST──► HTTP endpoint (0.0.0.0:8765)
  Local agents / DatasetRunner       ──Unix socket──► /tmp/flexaidds_agent_hub.sock
                                                        │
                                               Shannon Gate (this process)
                                                        │
                                              ┌─────────┴──────────┐
                                           SQLite               Broadcast
                                         audit log           to other agents

Dependencies
------------
  Python 3.11+
  aiohttp (optional, for HTTP endpoint): pip install aiohttp

Usage
-----
  python shannon_gate.py                    # foreground
  python shannon_gate.py --daemon           # background (nohup wrapper)
  python shannon_gate.py --http-host 0.0.0.0 --http-port 8765

Environment
-----------
  FLEXAIDDS_LOG_DIR   Override default log/DB directory
  SHANNON_H_THRESHOLD Override flag threshold (default 3.5)
  SHANNON_H_BLOCK     Override block threshold (default 5.0)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import os
import secrets
import signal
import sqlite3
import sys
import time
from collections import Counter, defaultdict, deque
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Optional

# ── Optional dependency ────────────────────────────────────────────────────────
try:
    from aiohttp import web as _aiohttp_web
    HAS_AIOHTTP = True
except ImportError:
    HAS_AIOHTTP = False

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%S",
)
logger = logging.getLogger("shannon_gate")

# ── Configuration (override via env vars or CLI args) ─────────────────────────
SOCKET_PATH: str = "/tmp/shannon.sock"
HTTP_HOST: str = os.environ.get("SHANNON_HTTP_HOST", "127.0.0.1")
HTTP_PORT: int = int(os.environ.get("SHANNON_HTTP_PORT", "8765"))

# Log / DB directory — override via SHANNON_LOG_DIR (preferred) or the legacy
# FLEXAIDDS_LOG_DIR env var.  Default is ~/.shannon so the repo is self-contained
# and fully decoupled from any downstream project (FlexAIDdS, proteomics, etc.).
_log_dir_env = (
    os.environ.get("SHANNON_LOG_DIR")
    or os.environ.get("FLEXAIDDS_LOG_DIR")   # backward compat for existing deployments
)
LOG_DIR: Path = Path(_log_dir_env) if _log_dir_env else Path.home() / ".shannon"
DB_PATH: Path = LOG_DIR / "agent_hub.db"

# Shannon gate thresholds
H_THRESHOLD: float = float(os.environ.get("SHANNON_H_THRESHOLD", "3.5"))
H_BLOCK_THRESHOLD: float = float(os.environ.get("SHANNON_H_BLOCK", "5.0"))
D_THRESHOLD: float = float(os.environ.get("SHANNON_D_THRESHOLD", "1.8"))
H_TEMPORAL_SPIKE: float = 2.0   # flag when agent's behavioral entropy exceeds this
TEMPORAL_WINDOW: int = 20        # rolling message-type history per agent
CF_DISAGREE_PCT: float = 0.05   # 5% CF disagreement triggers D flag

# Valid agent identifiers
VALID_AGENTS: frozenset[str] = frozenset({
    "codex",
    "cowork",
    "dispatch",
    "science",
    "grok_build",
    "claude_code",      # local coding agent — C++ compilation, git, shell tasks
    "dataset_runner",   # local DatasetRunner bridge
    "local_test",       # development / integration testing
})

VALID_MESSAGE_TYPES: frozenset[str] = frozenset({
    "result",
    "status",
    "query",
    "alert",
    "code_suggestion",
    "benchmark_update",
    "system_event",   # resource alerts / approvals from the HUD
    "approval_needed",  # agent asks human for yes/no
    "approval_response",  # human resolution echoed back
    "ping",
})

# ── Shared socket secret (memory only — never persisted, never logged) ─────────
# Generated fresh at each daemon startup; distributed to local agents via the
# /tmp/flexaidds_agent_hub.sock handshake.  Cloud agents use API keys (Keychain).
HUB_SECRET: str = secrets.token_hex(32)


# ── Data classes ──────────────────────────────────────────────────────────────

@dataclass
class AgentMessage:
    agent_id: str
    task_id: str
    message_type: str
    payload: dict[str, Any]
    timestamp_ns: int
    shannon_H: float        # self-reported by agent (or 0 if not provided)
    confidence: float       # self-reported confidence in [0, 1]
    message_id: str = ""


@dataclass
class GateDecision:
    decision: str           # "pass" | "flagged" | "blocked"
    reasons: list[str]
    computed_H: float       # gate-computed output entropy
    computed_D: float       # gate-computed disagreement entropy (0 if N/A)
    computed_H_temporal: float = 0.0


# ── Shannon Entropy Analyzer ──────────────────────────────────────────────────

class ShannonAnalyzer:
    """
    Information-theoretic analysis of agent outputs.
    All entropy values are in bits (log base 2).
    """

    # ── Output entropy ────────────────────────────────────────────────────────

    @staticmethod
    def token_entropy(text: str) -> float:
        """
        H_output = -Σ_{t ∈ vocab} p(t) log₂ p(t)

        Uses whitespace tokenization as a proxy for subword tokens.
        For production replace with a tokenizer (tiktoken, sentencepiece, etc.).
        Normalise to lower-case so capitalisation doesn't inflate entropy.
        """
        if not text or not text.strip():
            return 0.0
        tokens = text.lower().split()
        n = len(tokens)
        if n < 2:
            return 0.0
        counts = Counter(tokens)
        # max(0.0, …) collapses the -0.0 that a degenerate (single-token)
        # distribution produces, since -1.0 * log2(1.0) is negative zero.
        return max(0.0, -sum((c / n) * math.log2(c / n) for c in counts.values()))

    @staticmethod
    def structural_entropy(payload: dict[str, Any]) -> float:
        """
        Character-level entropy of the JSON-serialised payload.
        Catches structured deception: plausible-looking JSON with internally
        inconsistent numerical distributions.
        """
        text = json.dumps(payload, sort_keys=True)
        n = len(text)
        if n < 4:
            return 0.0
        counts = Counter(text)
        return max(0.0, -sum((c / n) * math.log2(c / n) for c in counts.values()))

    @classmethod
    def combined_entropy(cls, payload: dict[str, Any]) -> float:
        """
        Weighted combination:
          H = 0.70 * H_token(text fields) + 0.30 * H_struct(JSON structure)

        When no text content is present, falls back to structural entropy alone.
        """
        text_parts: list[str] = []
        for key in ("text", "content", "output", "message", "code",
                    "analysis", "rationale", "suggested_code"):
            val = payload.get(key)
            if isinstance(val, str):
                text_parts.append(val)

        text = " ".join(text_parts)
        H_struct = cls.structural_entropy(payload)

        if text.strip():
            H_text = cls.token_entropy(text)
            return round(0.70 * H_text + 0.30 * H_struct, 4)
        return round(H_struct, 4)

    # ── Disagreement entropy ──────────────────────────────────────────────────

    @staticmethod
    def disagreement_entropy(cf_map: dict[str, float]) -> float:
        """
        D_agents = -Σ_k p_k log₂ p_k
        where p_k = softmax(-CF_k)
        (lower CF score ⇒ better pose ⇒ higher probability weight)

        High D means agents strongly disagree on which pose is best.
        """
        if len(cf_map) < 2:
            return 0.0
        neg = [-v for v in cf_map.values()]
        max_neg = max(neg)
        exp_v = [math.exp(v - max_neg) for v in neg]   # numerically stable
        total = sum(exp_v)
        probs = [e / total for e in exp_v]
        return round(max(0.0, -sum(p * math.log2(p) for p in probs if p > 1e-12)), 4)

    # ── Temporal entropy ──────────────────────────────────────────────────────

    @staticmethod
    def temporal_entropy(history: list[str]) -> float:
        """
        H_temporal(i) = -Σ_{type} p_type log₂ p_type

        A sudden spike indicates the agent has shifted its behaviour pattern —
        e.g., a status-only agent starting to emit code_suggestions and alerts
        is worth flagging for review.
        """
        if len(history) < 3:
            return 0.0
        counts = Counter(history)
        total = len(history)
        return round(max(0.0, -sum((c / total) * math.log2(c / total)
                                   for c in counts.values())), 4)


# ── Audit Database ────────────────────────────────────────────────────────────

class AuditDB:
    """Thread-safe (via WAL mode) SQLite audit log."""

    def __init__(self, db_path: Path) -> None:
        self.db_path = db_path
        db_path.parent.mkdir(parents=True, exist_ok=True)
        self._init_schema()

    # ── DDL ───────────────────────────────────────────────────────────────────

    def _init_schema(self) -> None:
        with self._connect() as conn:
            conn.executescript("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;

                -- Live agent registry — polled by the Swift HUD every 0.5 s
                CREATE TABLE IF NOT EXISTS agents (
                    agent_id        TEXT PRIMARY KEY,
                    status          TEXT NOT NULL DEFAULT 'idle',
                    connected_at    INTEGER,
                    last_seen_ns    INTEGER NOT NULL DEFAULT 0,
                    disconnected_at INTEGER,
                    task_id         TEXT DEFAULT '',
                    message_count   INTEGER DEFAULT 0,
                    entropy_score   REAL DEFAULT 0.0,
                    task_summary    TEXT DEFAULT '',
                    auth_method     TEXT DEFAULT 'socket_secret'
                );

                CREATE TABLE IF NOT EXISTS agent_messages (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    received_at_ns  INTEGER NOT NULL,
                    agent_id        TEXT NOT NULL,
                    task_id         TEXT NOT NULL,
                    message_type    TEXT NOT NULL,
                    message_id      TEXT,
                    payload_json    TEXT NOT NULL,
                    timestamp_ns    INTEGER,
                    self_H          REAL,
                    self_conf       REAL,
                    gate_H          REAL,
                    gate_D          REAL,
                    gate_H_temporal REAL,
                    gate_decision   TEXT,
                    gate_reasons    TEXT
                );

                -- Generic benchmark/task progress table.
                -- Column names match what update_benchmark_state() inserts.
                CREATE TABLE IF NOT EXISTS benchmark_state (
                    id            INTEGER PRIMARY KEY AUTOINCREMENT,
                    updated_at    INTEGER NOT NULL,
                    task_id       TEXT NOT NULL,
                    completed     INTEGER DEFAULT 0,
                    total         INTEGER DEFAULT 85,
                    best_cf       REAL,
                    best_rmsd     REAL,
                    active_target TEXT,
                    state_json    TEXT NOT NULL
                );

                CREATE TABLE IF NOT EXISTS agent_cf_reports (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    reported_at INTEGER NOT NULL,
                    agent_id    TEXT NOT NULL,
                    task_id     TEXT NOT NULL,
                    target_id   TEXT,
                    cf_value    REAL NOT NULL,
                    rmsd        REAL,
                    pose_file   TEXT
                );

                CREATE INDEX IF NOT EXISTS idx_msg_agent_time
                    ON agent_messages(agent_id, received_at_ns);
                CREATE INDEX IF NOT EXISTS idx_msg_decision
                    ON agent_messages(gate_decision, received_at_ns);
                CREATE INDEX IF NOT EXISTS idx_agents_status
                    ON agents(status);
                CREATE INDEX IF NOT EXISTS idx_bench_task
                    ON benchmark_state(task_id, updated_at);

                CREATE TABLE IF NOT EXISTS login_events (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id     TEXT NOT NULL,
                    event_at_ns  INTEGER NOT NULL,
                    auth_method  TEXT NOT NULL,   -- 'socket_secret' | 'api_key' | 'oauth'
                    auth_success INTEGER NOT NULL, -- 0 or 1
                    details      TEXT             -- optional JSON, NO secrets stored here
                );
                CREATE INDEX IF NOT EXISTS idx_login_agent
                    ON login_events(agent_id, event_at_ns);

                CREATE TABLE IF NOT EXISTS agent_activity (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id     TEXT NOT NULL,
                    event_at_ns  INTEGER NOT NULL,
                    event_type   TEXT NOT NULL,   -- 'tool_call' | 'dock' | 'build' | 'edit' | 'bash'
                    event_label  TEXT NOT NULL,   -- e.g. "Dock(1SG0)"
                    event_output TEXT             -- e.g. "CF=−187.3, RMSD=1.14Å"
                );
                CREATE INDEX IF NOT EXISTS idx_activity_agent
                    ON agent_activity(agent_id, event_at_ns);

                CREATE TABLE IF NOT EXISTS delegations (
                    id               INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id         TEXT NOT NULL,
                    task_text        TEXT NOT NULL,
                    dispatched_at_ns INTEGER NOT NULL,
                    outcome          TEXT DEFAULT 'pending'  -- 'pending'|'accepted'|'completed'|'rejected'
                );
            """)
            # Additive migration for existing databases
            self._migrate_schema(conn)

    def _migrate_schema(self, conn: sqlite3.Connection) -> None:
        """Rename/add columns in benchmark_state to match the current INSERT signature."""
        bs_cols = {row[1] for row in conn.execute("PRAGMA table_info(benchmark_state)").fetchall()}
        # Rename legacy 'progress' → 'completed'
        if "progress" in bs_cols and "completed" not in bs_cols:
            conn.execute("ALTER TABLE benchmark_state RENAME COLUMN progress TO completed")
            bs_cols.discard("progress")
            bs_cols.add("completed")
        for col_name, col_def in [
            ("completed",     "INTEGER DEFAULT 0"),
            ("total",         "INTEGER DEFAULT 85"),
            ("best_cf",       "REAL"),
            ("best_rmsd",     "REAL"),
            ("active_target", "TEXT"),
        ]:
            if col_name not in bs_cols:
                try:
                    conn.execute(
                        f"ALTER TABLE benchmark_state ADD COLUMN {col_name} {col_def}"
                    )
                except sqlite3.OperationalError:
                    pass  # already present (race between processes)

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(str(self.db_path), timeout=10)
        conn.row_factory = sqlite3.Row
        return conn

    # ── Write helpers ─────────────────────────────────────────────────────────

    def log_message(
        self,
        msg: AgentMessage,
        decision: GateDecision,
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO agent_messages
                    (received_at_ns, agent_id, task_id, message_type, message_id,
                     payload_json, timestamp_ns, self_H, self_conf,
                     gate_H, gate_D, gate_H_temporal, gate_decision, gate_reasons)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    time.time_ns(),
                    msg.agent_id, msg.task_id, msg.message_type, msg.message_id,
                    json.dumps(msg.payload),
                    msg.timestamp_ns, msg.shannon_H, msg.confidence,
                    decision.computed_H, decision.computed_D,
                    decision.computed_H_temporal,
                    decision.decision, json.dumps(decision.reasons),
                ),
            )

    def log_cf_report(
        self,
        agent_id: str,
        task_id: str,
        target_id: str,
        cf_value: float,
        rmsd: Optional[float],
        pose_file: Optional[str],
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO agent_cf_reports
                    (reported_at, agent_id, task_id, target_id, cf_value, rmsd, pose_file)
                VALUES (?,?,?,?,?,?,?)
                """,
                (time.time_ns(), agent_id, task_id, target_id, cf_value, rmsd, pose_file),
            )

    def log_auth_event(
        self,
        agent_id: str,
        auth_method: str,
        success: bool,
        details: Optional[dict[str, Any]] = None,
    ) -> None:
        """
        Record an authentication event.  NO secrets are stored — only metadata.

        Parameters
        ----------
        agent_id    : agent that authenticated (or attempted to)
        auth_method : 'socket_secret' | 'api_key' | 'oauth'
        success     : True if auth passed
        details     : Optional extra context (e.g. {"reason": "token_expired"}).
                      Must NOT contain tokens, passwords, or raw secrets.
        """
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO login_events
                    (agent_id, event_at_ns, auth_method, auth_success, details)
                VALUES (?, ?, ?, ?, ?)
                """,
                (
                    agent_id,
                    time.time_ns(),
                    auth_method,
                    1 if success else 0,
                    json.dumps(details) if details else None,
                ),
            )

    def upsert_agent(
        self,
        agent_id: str,
        status: str,
        connected_at_ns: int,
        auth_method: str = "socket_secret",
    ) -> None:
        """INSERT or UPDATE the agents row when a socket connection is established."""
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO agents
                    (agent_id, status, connected_at, last_seen_ns, auth_method,
                     disconnected_at, message_count)
                VALUES (?, ?, ?, ?, ?, NULL, 0)
                ON CONFLICT(agent_id) DO UPDATE SET
                    status          = excluded.status,
                    connected_at    = excluded.connected_at,
                    last_seen_ns    = excluded.last_seen_ns,
                    auth_method     = excluded.auth_method,
                    disconnected_at = NULL,
                    message_count   = 0
                """,
                (agent_id, status, connected_at_ns, connected_at_ns, auth_method),
            )

    def update_agent_seen(
        self,
        agent_id: str,
        last_seen_ns: int,
        entropy_score: float,
        task_id: str,
        *,
        task_summary: str = "",
        status: str = "active",
    ) -> None:
        """Increment message_count, refresh last_seen_ns and entropy after each message."""
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE agents SET
                    last_seen_ns  = ?,
                    entropy_score = ?,
                    task_id       = ?,
                    message_count = message_count + 1,
                    status        = ?,
                    task_summary  = CASE
                        WHEN ? != '' THEN ?
                        ELSE task_summary
                    END
                WHERE agent_id = ?
                """,
                (
                    last_seen_ns,
                    entropy_score,
                    task_id,
                    status or "active",
                    task_summary or "",
                    task_summary or "",
                    agent_id,
                ),
            )

    def upsert_interaction(
        self,
        interaction_id: str,
        agent_id: str,
        prompt: str,
        status: str = "pending",
    ) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS agent_interactions (
                    interaction_id TEXT PRIMARY KEY,
                    agent_id       TEXT NOT NULL,
                    prompt         TEXT NOT NULL,
                    status         TEXT NOT NULL DEFAULT 'pending',
                    created_at_ns  INTEGER NOT NULL,
                    resolved_at_ns INTEGER
                )
                """
            )
            conn.execute(
                """
                INSERT INTO agent_interactions
                    (interaction_id, agent_id, prompt, status, created_at_ns)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(interaction_id) DO UPDATE SET
                    prompt = excluded.prompt,
                    status = excluded.status,
                    resolved_at_ns = CASE
                        WHEN excluded.status IN ('approved','denied')
                        THEN ? ELSE agent_interactions.resolved_at_ns END
                """,
                (
                    interaction_id,
                    agent_id,
                    prompt,
                    status,
                    time.time_ns(),
                    time.time_ns(),
                ),
            )

    def resolve_interaction(self, interaction_id: str, approved: bool) -> Optional[dict]:
        status = "approved" if approved else "denied"
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS agent_interactions (
                    interaction_id TEXT PRIMARY KEY,
                    agent_id       TEXT NOT NULL,
                    prompt         TEXT NOT NULL,
                    status         TEXT NOT NULL DEFAULT 'pending',
                    created_at_ns  INTEGER NOT NULL,
                    resolved_at_ns INTEGER
                )
                """
            )
            conn.execute(
                """
                UPDATE agent_interactions SET
                    status = ?,
                    resolved_at_ns = ?
                WHERE interaction_id = ?
                """,
                (status, time.time_ns(), interaction_id),
            )
            row = conn.execute(
                "SELECT interaction_id, agent_id, prompt, status FROM agent_interactions "
                "WHERE interaction_id = ?",
                (interaction_id,),
            ).fetchone()
            if not row:
                return None
            return {
                "interaction_id": row[0],
                "agent_id": row[1],
                "prompt": row[2],
                "status": row[3],
            }

    def list_pending_interactions(self) -> list[dict]:
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS agent_interactions (
                    interaction_id TEXT PRIMARY KEY,
                    agent_id       TEXT NOT NULL,
                    prompt         TEXT NOT NULL,
                    status         TEXT NOT NULL DEFAULT 'pending',
                    created_at_ns  INTEGER NOT NULL,
                    resolved_at_ns INTEGER
                )
                """
            )
            rows = conn.execute(
                "SELECT interaction_id, agent_id, prompt, status, created_at_ns "
                "FROM agent_interactions WHERE status = 'pending' "
                "ORDER BY created_at_ns DESC LIMIT 50"
            ).fetchall()
            return [
                {
                    "interaction_id": r[0],
                    "agent_id": r[1],
                    "prompt": r[2],
                    "status": r[3],
                    "created_at_ns": r[4],
                }
                for r in rows
            ]

    def update_agent_disconnect(self, agent_id: str, disconnected_at_ns: int) -> None:
        """Mark agent idle on socket disconnect."""
        with self._connect() as conn:
            conn.execute(
                """
                UPDATE agents SET
                    status          = 'idle',
                    disconnected_at = ?
                WHERE agent_id = ?
                """,
                (disconnected_at_ns, agent_id),
            )

    def log_activity_event(
        self,
        agent_id: str,
        event_type: str,
        event_label: str,
        event_output: Optional[str] = None,
    ) -> None:
        """Record a Vibe Island-style tool-call event for the HUD activity feed."""
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO agent_activity
                    (agent_id, event_at_ns, event_type, event_label, event_output)
                VALUES (?, ?, ?, ?, ?)
                """,
                (agent_id, time.time_ns(), event_type, event_label, event_output),
            )

    def insert_delegation(
        self,
        agent_id: str,
        task_text: str,
    ) -> int:
        """Insert a delegation record and return its row id."""
        with self._connect() as conn:
            cur = conn.execute(
                """
                INSERT INTO delegations (agent_id, task_text, dispatched_at_ns)
                VALUES (?, ?, ?)
                """,
                (agent_id, task_text, time.time_ns()),
            )
            return cur.lastrowid or 0

    def update_delegation_outcome(self, row_id: int, outcome: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE delegations SET outcome=? WHERE id=?",
                (outcome, row_id),
            )

    def update_benchmark_state(self, task_id: str, state: dict[str, Any]) -> None:
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO benchmark_state
                    (updated_at, task_id, completed, total,
                     best_cf, best_rmsd, active_target, state_json)
                VALUES (?,?,?,?,?,?,?,?)
                """,
                (
                    time.time_ns(), task_id,
                    state.get("completed", 0),
                    state.get("total", 85),
                    state.get("best_cf"),
                    state.get("best_rmsd"),
                    state.get("active_target"),
                    json.dumps(state),
                ),
            )

    # ── Read helpers ──────────────────────────────────────────────────────────

    def get_recent_messages(self, limit: int = 100) -> list[dict]:
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT * FROM agent_messages
                ORDER BY received_at_ns DESC LIMIT ?
                """,
                (limit,),
            ).fetchall()
            return [dict(r) for r in rows]

    def get_latest_benchmark_state(self) -> Optional[dict]:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT * FROM benchmark_state
                ORDER BY updated_at DESC LIMIT 1
                """
            ).fetchone()
            return dict(row) if row else None

    def get_latest_cf_per_agent(self, task_id: str) -> dict[str, float]:
        """Returns {agent_id: latest_reported_cf} for disagreement computation."""
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT agent_id, cf_value
                FROM agent_cf_reports
                WHERE task_id = ?
                  AND reported_at = (
                        SELECT MAX(reported_at) FROM agent_cf_reports a2
                        WHERE a2.agent_id = agent_cf_reports.agent_id
                          AND a2.task_id  = agent_cf_reports.task_id
                      )
                """,
                (task_id,),
            ).fetchall()
            return {r["agent_id"]: r["cf_value"] for r in rows}

    def flagged_count(self, since_ns: int = 0) -> int:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT COUNT(*) FROM agent_messages
                WHERE gate_decision IN ('flagged', 'blocked')
                  AND received_at_ns > ?
                """,
                (since_ns,),
            ).fetchone()
            return row[0] if row else 0


# ── Shannon Gate ──────────────────────────────────────────────────────────────

class ShannonGate:
    """
    Stateful gate: evaluates every AgentMessage and returns a GateDecision.

    State it maintains:
      _temporal_history  — per-agent rolling deque of message_types
      _cf_cache          — per-(task_id, agent_id) latest CF value
    """

    def __init__(self, db: AuditDB) -> None:
        self.db = db
        self.analyzer = ShannonAnalyzer()
        self._temporal_history: dict[str, deque[str]] = defaultdict(
            lambda: deque(maxlen=TEMPORAL_WINDOW)
        )
        # {task_id: {agent_id: cf_value}}
        self._cf_cache: dict[str, dict[str, float]] = defaultdict(dict)

    def evaluate(self, msg: AgentMessage) -> GateDecision:
        reasons: list[str] = []

        # ── 1. Compute gate-side output entropy ───────────────────────────────
        H = round(self.analyzer.combined_entropy(msg.payload), 4)

        # ── 2. Extract CF value if present (docking result) ───────────────────
        D = 0.0
        cf_val = msg.payload.get("cf_value") or msg.payload.get("best_cf")
        if cf_val is not None:
            try:
                cf_f = float(cf_val)
                self._cf_cache[msg.task_id][msg.agent_id] = cf_f
                self.db.log_cf_report(
                    msg.agent_id, msg.task_id,
                    str(msg.payload.get("target_id", "unknown")),
                    cf_f,
                    msg.payload.get("rmsd"),
                    msg.payload.get("pose_file"),
                )
                # Check CF disagreement across agents
                if len(self._cf_cache[msg.task_id]) >= 2:
                    D = self.analyzer.disagreement_entropy(
                        self._cf_cache[msg.task_id]
                    )
                    # Also flag if any two CF values differ by > 5 %
                    vals = list(self._cf_cache[msg.task_id].values())
                    span = max(vals) - min(vals)
                    baseline = abs(min(vals)) + 1e-9
                    if span / baseline > CF_DISAGREE_PCT:
                        reasons.append(
                            f"CF_disagreement({span/baseline*100:.1f}%>5%)"
                        )
            except (ValueError, TypeError):
                pass

        # ── 3. Temporal entropy ───────────────────────────────────────────────
        self._temporal_history[msg.agent_id].append(msg.message_type)
        H_temp = self.analyzer.temporal_entropy(
            list(self._temporal_history[msg.agent_id])
        )

        # ── 4. Self-reported confidence check ─────────────────────────────────
        if msg.confidence < 0.50:
            reasons.append(f"low_self_confidence({msg.confidence:.2f})")

        # ── 5. Entropy mismatch: agent claims low H but gate sees high H ───────
        if msg.shannon_H > 0 and H > 0:
            ratio = H / (msg.shannon_H + 1e-9)
            if ratio > 2.5:
                reasons.append(
                    f"H_mismatch(self={msg.shannon_H:.2f},gate={H:.2f})"
                )

        # ── 6. Gate decision tree ─────────────────────────────────────────────
        decision: str

        if H >= H_BLOCK_THRESHOLD:
            reasons.append(
                f"H_hard_block({H:.2f}>={H_BLOCK_THRESHOLD})"
            )
            if msg.message_type == "code_suggestion":
                reasons.append("code_suggestion_hard_blocked")
            decision = "blocked"

        elif H >= H_THRESHOLD:
            reasons.append(f"H_flag({H:.2f}>={H_THRESHOLD})")
            decision = "flagged"

        elif D >= D_THRESHOLD:
            reasons.append(f"D_flag({D:.2f}>={D_THRESHOLD})")
            decision = "flagged"

        elif (H_temp >= H_TEMPORAL_SPIKE
              and len(self._temporal_history[msg.agent_id]) >= 10):
            reasons.append(f"H_temporal_spike({H_temp:.2f}>={H_TEMPORAL_SPIKE})")
            decision = "flagged"

        else:
            decision = "pass"

        gate_decision = GateDecision(
            decision=decision,
            reasons=reasons,
            computed_H=H,
            computed_D=D,
            computed_H_temporal=H_temp,
        )

        # ── 7. Persist to audit log ───────────────────────────────────────────
        self.db.log_message(msg, gate_decision)

        return gate_decision


# ── Agent Connection (socket) ─────────────────────────────────────────────────

class AgentConn:
    """Wraps a single async TCP/Unix stream connection for one agent."""

    __slots__ = ("reader", "writer", "agent_id", "connected_at")

    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        agent_id: str,
    ) -> None:
        self.reader = reader
        self.writer = writer
        self.agent_id = agent_id
        self.connected_at = time.time_ns()

    async def send_json(self, data: dict[str, Any]) -> None:
        try:
            self.writer.write(json.dumps(data).encode() + b"\n")
            await self.writer.drain()
        except Exception as exc:
            logger.debug(f"send_json({self.agent_id}): {exc}")

    def close(self) -> None:
        try:
            self.writer.close()
        except Exception:
            pass


# ── Agent Hub ─────────────────────────────────────────────────────────────────

class AgentHub:
    """
    Central broker.
    - Manages Unix socket server (local agents / DatasetRunner)
    - Manages optional HTTP server (cloud agents)
    - Runs Shannon gate on every incoming message
    - Broadcasts gated messages to all other connected agents
    """

    def __init__(self, http_host: str = HTTP_HOST, http_port: int = HTTP_PORT) -> None:
        self.http_host = http_host
        self.http_port = http_port

        self.db = AuditDB(DB_PATH)
        self.gate = ShannonGate(self.db)
        self._connections: dict[str, AgentConn] = {}
        # Create Lock/Event inside the running loop (not at import/__init__).
        self._lock: Optional[asyncio.Lock] = None
        self._shutdown: Optional[asyncio.Event] = None

        # Live benchmark state (updated by dataset_runner agent)
        self._benchmark: dict[str, Any] = {
            "completed": 0,
            "total": 85,
            "best_cf": None,
            "best_rmsd": None,
            "active_target": None,
            "task_id": "unknown",
        }

    # ── Unix socket server ────────────────────────────────────────────────────

    async def _handle_socket_conn(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        peer = writer.get_extra_info("peername") or "unix"
        agent_id: Optional[str] = None
        conn: Optional[AgentConn] = None

        try:
            # First message: registration {"agent_id": "...", "task_id": "..."}
            raw = await asyncio.wait_for(reader.readline(), timeout=10.0)
            reg = json.loads(raw.decode().strip())
            agent_id = reg.get("agent_id", "")

            if agent_id not in VALID_AGENTS:
                await self._reject(writer, f"unknown_agent:{agent_id}")
                return

            conn = AgentConn(reader, writer, agent_id)
            async with self._lock:
                if agent_id in self._connections:
                    logger.warning(f"Replacing existing connection for {agent_id}")
                self._connections[agent_id] = conn

            self.db.upsert_agent(agent_id, "active", conn.connected_at)
            logger.info(f"[+] {agent_id} connected ({peer})")

            # Welcome: send current benchmark state
            await conn.send_json({
                "type": "welcome",
                "agent_id": agent_id,
                "benchmark": self._benchmark,
                "thresholds": {
                    "H_flag": H_THRESHOLD,
                    "H_block": H_BLOCK_THRESHOLD,
                    "D_flag": D_THRESHOLD,
                },
            })

            # Message loop
            buf = b""
            while not self._shutdown.is_set():
                try:
                    chunk = await asyncio.wait_for(reader.read(65536), timeout=90.0)
                    if not chunk:
                        break
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            data = json.loads(line.decode())
                        except json.JSONDecodeError as e:
                            logger.debug(f"Bad JSON from {agent_id}: {e}")
                            continue
                        await self._dispatch(data, conn)
                except asyncio.TimeoutError:
                    await conn.send_json({"type": "ping"})

        except asyncio.IncompleteReadError:
            pass
        except Exception as exc:
            logger.warning(f"Socket error ({agent_id or peer}): {exc}")
        finally:
            if agent_id:
                async with self._lock:
                    self._connections.pop(agent_id, None)
                self.db.update_agent_disconnect(agent_id, time.time_ns())
                logger.info(f"[-] {agent_id} disconnected")
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass

    # ── Message dispatch ──────────────────────────────────────────────────────

    async def _dispatch(
        self,
        data: dict[str, Any],
        source: AgentConn,
    ) -> None:
        """Parse, gate, and route one incoming JSON object."""

        # Pong for keepalive
        if data.get("type") == "pong" or data.get("type") == "ping":
            return

        try:
            msg = AgentMessage(
                agent_id=str(data.get("agent_id", source.agent_id)),
                task_id=str(data.get("task_id", "unknown")),
                message_type=str(data.get("message_type", "status")),
                payload=dict(data.get("payload", {})),
                timestamp_ns=int(data.get("timestamp_ns", time.time_ns())),
                shannon_H=float(data.get("shannon_H", 0.0)),
                confidence=float(data.get("confidence", 1.0)),
                message_id=str(data.get("message_id", "")),
            )
        except Exception as exc:
            logger.debug(f"Malformed message from {source.agent_id}: {exc}")
            return

        # Query messages bypass the gate (they are read-only)
        if msg.message_type == "query":
            await self._answer_query(msg, source)
            return

        # Human approval resolution from hub UI (does not re-gate).
        if msg.message_type in ("approval_response", "system_event") and (
            "approved" in msg.payload or msg.payload.get("kind") == "approval_response"
        ):
            iid = str(
                msg.payload.get("interaction_id")
                or msg.message_id
                or f"ask-{msg.agent_id}"
            )
            approved = bool(msg.payload.get("approved"))
            resolved = self.db.resolve_interaction(iid, approved)
            self.db.log_activity_event(
                msg.agent_id,
                "approval_response",
                f"{'approved' if approved else 'denied'}: {iid}",
                event_output=json.dumps(resolved or {}),
            )
            await source.send_json({
                "type": "approval_ack",
                "interaction_id": iid,
                "approved": approved,
                "record": resolved,
            })
            return

        # Run Shannon gate
        decision = self.gate.evaluate(msg)

        # Map payload → UI status (shared pure helper)
        try:
            from agent_identity import ask_from_payload, status_from_payload
        except ImportError:
            from hub.agent_identity import ask_from_payload, status_from_payload  # type: ignore

        status_upd = status_from_payload(
            msg.agent_id, msg.message_type, msg.payload
        )
        if msg.message_type == "approval_needed" or msg.payload.get("approval_needed"):
            status_upd = status_from_payload(
                msg.agent_id, "approval_needed", msg.payload
            )

        # Refresh agent registry — last_seen, entropy, task text for HUD/pill
        self.db.update_agent_seen(
            msg.agent_id,
            time.time_ns(),
            decision.computed_H,
            msg.task_id,
            task_summary=status_upd.task_summary,
            status=status_upd.status if decision.decision != "blocked" else "blocked",
        )

        if decision.decision in ("flagged", "blocked"):
            log_fn = logger.warning if decision.decision == "blocked" else logger.info
            log_fn(
                f"GATE {decision.decision.upper()} [{msg.agent_id}] "
                f"H={decision.computed_H:.2f} D={decision.computed_D:.2f} "
                f"reasons={decision.reasons}"
            )

        # Echo gate decision back to sender
        await source.send_json({
            "type": "gate_response",
            "message_id": msg.message_id,
            "decision": decision.decision,
            "gate_H": decision.computed_H,
            "gate_D": decision.computed_D,
            "gate_H_temporal": decision.computed_H_temporal,
            "reasons": decision.reasons,
        })

        if decision.decision == "blocked":
            self.db.log_activity_event(
                msg.agent_id, "blocked", status_upd.event_label,
                event_output="; ".join(decision.reasons),
            )
            return

        # Feed + activity for live surfaces
        self.db.log_activity_event(
            msg.agent_id,
            status_upd.event_type,
            status_upd.event_label,
            event_output=json.dumps(msg.payload)[:2000],
        )

        # Approval ask → persisted pending interaction for hub UI
        if (
            msg.message_type == "approval_needed"
            or msg.payload.get("approval_needed")
            or msg.payload.get("require_approval")
        ):
            ask = ask_from_payload(
                msg.agent_id,
                msg.payload,
                interaction_id=str(
                    msg.payload.get("interaction_id") or msg.message_id or ""
                )
                or None,
                force=True,
            )
            assert ask is not None
            self.db.upsert_interaction(
                ask.interaction_id, ask.agent_id, ask.prompt, "pending"
            )
            self.db.log_activity_event(
                msg.agent_id,
                "approval_needed",
                ask.prompt,
                event_output=ask.interaction_id,
            )

        # Update shared benchmark state
        if msg.message_type == "benchmark_update":
            self._benchmark.update({
                k: msg.payload[k]
                for k in ("completed", "total", "best_cf", "best_rmsd",
                          "active_target", "task_id")
                if k in msg.payload
            })
            self.db.update_benchmark_state(msg.task_id, self._benchmark)

        # Build broadcast envelope
        envelope: dict[str, Any] = {
            "type": "agent_message",
            "from": msg.agent_id,
            "message_type": msg.message_type,
            "task_id": msg.task_id,
            "payload": msg.payload,
            "gate_decision": decision.decision,
            "gate_H": decision.computed_H,
            "timestamp_ns": msg.timestamp_ns,
            "task_summary": status_upd.task_summary,
            "ui_status": status_upd.status,
        }
        if decision.decision == "flagged":
            envelope["gate_alert"] = {
                "severity": "warning",
                "reasons": decision.reasons,
                "computed_D": decision.computed_D,
            }

        await self._broadcast(envelope, exclude=source.agent_id)

    # ── Query handler ─────────────────────────────────────────────────────────

    async def _answer_query(self, msg: AgentMessage, conn: AgentConn) -> None:
        qt = msg.payload.get("query_type", "benchmark_state")

        if qt == "benchmark_state":
            state = self.db.get_latest_benchmark_state() or self._benchmark
            await conn.send_json({"type": "query_response",
                                  "query_type": qt, "data": state})

        elif qt == "agent_list":
            async with self._lock:
                ids = list(self._connections.keys())
            await conn.send_json({"type": "query_response",
                                  "query_type": qt,
                                  "data": {"connected": ids, "count": len(ids)}})

        elif qt == "cf_reports":
            task = msg.payload.get("task_id", msg.task_id)
            reports = self.db.get_latest_cf_per_agent(task)
            await conn.send_json({"type": "query_response",
                                  "query_type": qt, "data": reports})

        elif qt == "recent_messages":
            limit = int(msg.payload.get("limit", 50))
            rows = self.db.get_recent_messages(limit)
            await conn.send_json({"type": "query_response",
                                  "query_type": qt, "data": rows})

        else:
            await conn.send_json({"type": "query_response",
                                  "query_type": qt,
                                  "error": f"unknown query_type:{qt}"})

    # ── Broadcast ─────────────────────────────────────────────────────────────

    async def _broadcast(
        self,
        envelope: dict[str, Any],
        exclude: Optional[str] = None,
    ) -> None:
        async with self._lock:
            targets = {
                aid: c
                for aid, c in self._connections.items()
                if aid != exclude
            }
        for c in targets.values():
            await c.send_json(envelope)

    # ── Reject ────────────────────────────────────────────────────────────────

    @staticmethod
    async def _reject(writer: asyncio.StreamWriter, reason: str) -> None:
        try:
            writer.write(json.dumps({"error": reason}).encode() + b"\n")
            await writer.drain()
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass

    # ── HTTP endpoint (cloud agents) ──────────────────────────────────────────

    async def _start_http(self) -> None:
        if not HAS_AIOHTTP:
            logger.warning(
                "aiohttp not installed → HTTP endpoint disabled. "
                "Install: pip install aiohttp"
            )
            return

        from aiohttp import web

        async def post_message(request: web.Request) -> web.Response:
            try:
                data = await request.json()
            except Exception:
                return web.json_response({"error": "invalid_json"}, status=400)

            agent_id = str(data.get("agent_id", ""))
            if agent_id not in VALID_AGENTS:
                return web.json_response({"error": f"unknown_agent:{agent_id}"},
                                         status=403)

            # Handle query type inline
            if data.get("message_type") == "query":
                qt = data.get("payload", {}).get("query_type", "benchmark_state")
                if qt == "benchmark_state":
                    state = self.db.get_latest_benchmark_state() or self._benchmark
                    return web.json_response({"type": "query_response",
                                              "query_type": qt, "data": state})
                elif qt == "agent_list":
                    async with self._lock:
                        ids = list(self._connections.keys())
                    return web.json_response({"type": "query_response",
                                              "query_type": qt,
                                              "data": {"connected": ids}})

            try:
                msg = AgentMessage(
                    agent_id=agent_id,
                    task_id=str(data.get("task_id", "unknown")),
                    message_type=str(data.get("message_type", "status")),
                    payload=dict(data.get("payload", {})),
                    timestamp_ns=int(data.get("timestamp_ns", time.time_ns())),
                    shannon_H=float(data.get("shannon_H", 0.0)),
                    confidence=float(data.get("confidence", 1.0)),
                    message_id=str(data.get("message_id", "")),
                )
            except Exception as exc:
                return web.json_response({"error": str(exc)}, status=400)

            decision = self.gate.evaluate(msg)

            if decision.decision == "blocked":
                return web.json_response({
                    "decision": "blocked",
                    "gate_H": decision.computed_H,
                    "reasons": decision.reasons,
                }, status=200)

            if msg.message_type == "benchmark_update":
                self._benchmark.update({
                    k: msg.payload[k]
                    for k in ("completed", "total", "best_cf", "best_rmsd",
                              "active_target", "task_id")
                    if k in msg.payload
                })
                self.db.update_benchmark_state(msg.task_id, self._benchmark)

            # Broadcast to Unix socket subscribers
            envelope: dict[str, Any] = {
                "type": "agent_message",
                "from": msg.agent_id,
                "message_type": msg.message_type,
                "task_id": msg.task_id,
                "payload": msg.payload,
                "gate_decision": decision.decision,
                "gate_H": decision.computed_H,
                "timestamp_ns": msg.timestamp_ns,
            }
            if decision.decision == "flagged":
                envelope["gate_alert"] = {
                    "severity": "warning",
                    "reasons": decision.reasons,
                }
            await self._broadcast(envelope, exclude=agent_id)

            return web.json_response({
                "decision": decision.decision,
                "gate_H": decision.computed_H,
                "gate_D": decision.computed_D,
                "gate_H_temporal": decision.computed_H_temporal,
                "reasons": decision.reasons,
            })

        async def get_state(request: web.Request) -> web.Response:
            state = self.db.get_latest_benchmark_state() or self._benchmark
            return web.json_response(dict(state))

        async def get_health(request: web.Request) -> web.Response:
            async with self._lock:
                n = len(self._connections)
            return web.json_response({
                "status": "ok",
                "connected_agents": n,
                "db_path": str(DB_PATH),
                "thresholds": {
                    "H_flag": H_THRESHOLD,
                    "H_block": H_BLOCK_THRESHOLD,
                    "D_flag": D_THRESHOLD,
                },
            })

        async def get_messages(request: web.Request) -> web.Response:
            limit = int(request.rel_url.query.get("limit", "50"))
            rows = self.db.get_recent_messages(limit)
            return web.json_response(rows)

        app = web.Application()
        app.router.add_post("/message", post_message)
        app.router.add_get("/state", get_state)
        app.router.add_get("/health", get_health)
        app.router.add_get("/messages", get_messages)

        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, self.http_host, self.http_port)
        await site.start()
        logger.info(f"HTTP endpoint: http://{self.http_host}:{self.http_port}")
        logger.info("  POST /message   — submit agent message")
        logger.info("  GET  /state     — benchmark state")
        logger.info("  GET  /health    — health + threshold info")
        logger.info("  GET  /messages  — recent audit log")

    # ── Main run loop ─────────────────────────────────────────────────────────

    async def run(self) -> None:
        # Bind asyncio primitives to the running loop (fixes "attached to a different loop").
        self._lock = asyncio.Lock()
        self._shutdown = asyncio.Event()

        # Clean up stale socket
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)

        unix_server = await asyncio.start_unix_server(
            self._handle_socket_conn, path=SOCKET_PATH
        )
        os.chmod(SOCKET_PATH, 0o660)
        logger.info(f"Unix socket:   {SOCKET_PATH}")

        await self._start_http()

        # Signal handlers
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                loop.add_signal_handler(sig, self._on_shutdown)
            except NotImplementedError:
                pass  # Windows

        logger.info(
            f"Shannon Gate ready  (H_flag={H_THRESHOLD}, "
            f"H_block={H_BLOCK_THRESHOLD}, D_flag={D_THRESHOLD})"
        )
        logger.info(f"Audit DB: {DB_PATH}")

        async with unix_server:
            await self._shutdown.wait()

        logger.info("Shutting down…")
        async with self._lock:
            for c in self._connections.values():
                c.close()

        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        logger.info("Done.")

    def _on_shutdown(self) -> None:
        logger.info("Signal received — initiating graceful shutdown")
        if self._shutdown is not None:
            self._shutdown.set()


# ── CLI ───────────────────────────────────────────────────────────────────────

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="FlexAIDdS Shannon Gate — multi-agent entropy guardian"
    )
    p.add_argument("--http-host", default=HTTP_HOST,
                   help="HTTP bind address (default: 127.0.0.1; use 0.0.0.0 for LAN)")
    p.add_argument("--http-port", type=int, default=HTTP_PORT,
                   help="HTTP port (default: 8765)")
    p.add_argument("--socket", default=SOCKET_PATH,
                   help=f"Unix socket path (default: {SOCKET_PATH})")
    p.add_argument("--db", default=str(DB_PATH),
                   help="SQLite audit DB path")
    p.add_argument("--h-flag", type=float, default=H_THRESHOLD,
                   help="Shannon H flag threshold in bits (default: 3.5)")
    p.add_argument("--h-block", type=float, default=H_BLOCK_THRESHOLD,
                   help="Shannon H block threshold in bits (default: 5.0)")
    p.add_argument("--d-flag", type=float, default=D_THRESHOLD,
                   help="Agent disagreement D flag threshold (default: 1.8)")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="Set log level to DEBUG")
    return p.parse_args()


def main() -> None:
    args = _parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Apply CLI overrides to module-level constants
    global SOCKET_PATH, DB_PATH, H_THRESHOLD, H_BLOCK_THRESHOLD, D_THRESHOLD
    SOCKET_PATH = args.socket
    DB_PATH = Path(args.db)
    H_THRESHOLD = args.h_flag
    H_BLOCK_THRESHOLD = args.h_block
    D_THRESHOLD = args.d_flag

    hub = AgentHub(http_host=args.http_host, http_port=args.http_port)
    asyncio.run(hub.run())


if __name__ == "__main__":
    main()
