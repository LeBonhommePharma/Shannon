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
import statistics
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


# ── Self-report attestation ───────────────────────────────────────────────────
# ONE SENTENCE FOR THE OPERATOR:
#   An agent that tells the gate its output is simple, on text the gate can see
#   is complex, gets flagged — and if it keeps doing it, blocked.
#
# Why this exists
# ---------------
# The gate used to compute a self-report mismatch and then throw it away: the
# reason string "H_mismatch(self=1.00,gate=4.58)" was appended to `reasons` and
# the decision tree never looked at it.  A disagreement between what an agent
# claims about itself and what is independently measured is a far stronger
# deception primitive than absolute entropy — absolute entropy cannot tell a
# confidently-correct agent from a confidently-wrong one — so it is now
# load-bearing.
#
# Two things had to be fixed first, or the signal is noise:
#
#   1. THE TWO SIDES MUST MEASURE THE SAME BYTES.  The old check compared the
#      gate's *blended* H (0.70*token + 0.30*character) against the client's
#      *token* entropy, over a hardcoded 8-key allowlist that did not include
#      "prompt".  Replaying the operator's own 43 production messages: every
#      one of the 5 H_mismatch firings ever recorded was an approval prompt
#      whose text the gate could not see, so it compared JSON punctuation
#      entropy (~4.3-4.6 bits) against a correct token entropy.  Observed
#      precision: 0/5.  Escalating on that statistic would have flagged every
#      approval request — the traffic the human reads most — and the check
#      would have been switched off within a day.  See scored_text().
#
#   2. THE STATISTIC MUST BE A SLOPE, NOT A CLIFF.  A hard `ratio > 2.5` with
#      the constant compiled into the source (and printed back to the agent in
#      the reason string) is a boundary to sit just inside.  The per-message
#      rule below is backed by a per-agent accumulator that integrates small
#      persistent under-reporting into a verdict even when no single message
#      crosses a bound.
#
# Modes (SHANNON_ATTEST):
#   off      — compute nothing, legacy behaviour
#   observe  — compute + persist divergence and reasons, change NO verdict
#   enforce  — divergence can escalate pass -> flagged -> blocked  (default)
#
# Default is `enforce` because the stated bug is that the signal is cosmetic,
# and because the rules below fire on 0 of the operator's 43 real messages.
# An operator who wants to look before leaping runs SHANNON_ATTEST=observe for
# a week and reads `python hub/shannon_gate.py --attest-report`.
ATTEST_MODE: str = os.environ.get("SHANNON_ATTEST", "enforce").strip().lower()

# Text keys scored with priority. This list is THE shared definition — the
# client library imports it so both sides measure the same bytes. Adding
# "prompt" alone removes 2 of the 4 H>=3.5 flags on the operator's real
# traffic, both of them false positives, including the flagship 4.58.
SCORED_TEXT_KEYS: tuple[str, ...] = (
    "text", "content", "output", "message", "code", "analysis", "rationale",
    "suggested_code", "prompt", "summary", "description", "details", "result",
    "body", "reason", "answer", "patch", "diff",
)

# Keys whose string values are identifiers/labels, not content. Everything NOT
# in here is scored, at any nesting depth — an allowlist of scored keys is a
# denylist in disguise: it lets an agent put a benign string in `text` and the
# real payload in `result_body`.
METADATA_KEYS: frozenset[str] = frozenset({
    "agent_id", "task_id", "message_id", "interaction_id", "timestamp",
    "timestamp_ns", "id", "uuid", "kind", "type", "message_type", "status",
    "step", "source", "event", "event_type", "target_id", "pose_file",
    "shannon_h", "confidence", "approved", "approval_needed",
    "require_approval", "ui_status", "severity", "version", "hash", "sha",
})

# Dilution guard. H_token is a per-token MEAN, so appending free low-entropy
# padding ("ok " x 20000) drives it to ~0 no matter how much high-entropy
# content sits alongside. A statistic that is intensive can always be diluted
# by padding, so no single token may hold more than DILUTION_CAP_FRAC of a
# long stream when entropy is measured, and gross padding is flagged outright.
DILUTION_MIN_TOKENS: int = int(os.environ.get("SHANNON_DILUTION_MIN_TOKENS", "32"))
DILUTION_CAP_FRAC: float = float(os.environ.get("SHANNON_DILUTION_CAP_FRAC", "0.02"))
DILUTION_SHARE: float = float(os.environ.get("SHANNON_DILUTION_SHARE", "0.5"))

# Divergence d = log2(gate_token_H / self_reported_H), in bits.
#   d = 0.00 -> perfect agreement       d = 1.00 -> agent under-reported 2x
#   d = 1.50 -> under-reported 2.83x    d = 2.20 -> the production 1.00-vs-4.58
ATTEST_FLOOR: float = float(os.environ.get("SHANNON_ATTEST_FLOOR", "2.5"))
ATTEST_MARGIN: float = float(os.environ.get("SHANNON_ATTEST_MARGIN", "1.5"))
ATTEST_OVER_MARGIN: float = float(os.environ.get("SHANNON_ATTEST_OVER", "2.0"))
# Above this measured token entropy, saying nothing is itself an offence.
# Max token entropy among the operator's 11 real zero-self_H messages is 1.58,
# so this fires 0/43 with 1.42 bits of headroom.
UNATTESTED_FLOOR: float = float(os.environ.get("SHANNON_UNATTESTED_FLOOR", "3.0"))

# Per-agent accumulator. Residual e = max(0, d - min(bias_a, CAP) - TOL).
# Subtracting the agent's OWN learned bias is the false-positive firewall: a
# wrong tokenizer, a bits-vs-nats error or a client scoring a different field
# all produce a CONSTANT offset, which the median absorbs and the residual
# removes. Capping the bias is what stops an agent buying immunity by
# under-reporting consistently from its very first message.
ATTEST_TOL: float = float(os.environ.get("SHANNON_ATTEST_TOL", "0.25"))
ATTEST_BIAS_CAP: float = float(os.environ.get("SHANNON_ATTEST_BIAS_CAP", "0.5"))
ATTEST_ALPHA: float = float(os.environ.get("SHANNON_ATTEST_ALPHA", "0.3"))
ATTEST_FLAG_SCORE: float = float(os.environ.get("SHANNON_ATTEST_FLAG_SCORE", "0.6"))
ATTEST_BLOCK_SCORE: float = float(os.environ.get("SHANNON_ATTEST_BLOCK_SCORE", "1.0"))
ATTEST_MIN_N: int = int(os.environ.get("SHANNON_ATTEST_MIN_N", "5"))
ATTEST_MIN_OFFENCES: int = int(os.environ.get("SHANNON_ATTEST_MIN_OFFENCES", "3"))
ATTEST_CALIB_N: int = int(os.environ.get("SHANNON_ATTEST_CALIB_N", "10"))
ATTEST_WINDOW: int = int(os.environ.get("SHANNON_ATTEST_WINDOW", "20"))
ATTEST_HALFLIFE_H: float = float(os.environ.get("SHANNON_ATTEST_HALFLIFE_H", "24"))
ATTEST_SILENCE_W: float = float(os.environ.get("SHANNON_ATTEST_SILENCE_W", "0.5"))
# The incentive inversion: a demonstrated record of honest self-reporting is
# the ONLY way to buy entropy headroom. Never applied to the block threshold.
ATTEST_BONUS: float = float(os.environ.get("SHANNON_ATTEST_BONUS", "0.5"))

# What the measured party is told. "decision" = accept/flag/block verdict only
# (no measurements, no thresholds, no reason detail). "none" = a bare ack, for
# operators who can update every client. See _gate_response_envelope().
ECHO_MODE: str = os.environ.get("SHANNON_ECHO", "decision").strip().lower()
# Reject unknown message_type outright (1) or log and continue (0, default).
# VALID_MESSAGE_TYPES has drifted before, so the safe default is to observe.
STRICT_TYPES: bool = os.environ.get("SHANNON_STRICT_TYPES", "0") == "1"

# ── Liveness ──────────────────────────────────────────────────────────────────
# `last_seen_ns` only moves when an agent *speaks*, so a connected agent that
# has nothing to say is indistinguishable, on disk, from one whose gate was
# SIGKILLed with the connection still open (the `finally` that writes
# `disconnected_at` never runs). Readers used to guess from the age of
# `last_seen_ns`, which meant a perfectly healthy, quiet agent was reported
# "offline" after a few minutes.
#
# `heartbeat_ns` removes the guess: this daemon stamps it for every open
# connection on a fixed interval, so "connection is open" is an observed fact
# with a known freshness, while `last_seen_ns` keeps its real meaning of "last
# activity". A stale heartbeat means the daemon is gone, full stop.
HEARTBEAT_INTERVAL_S: float = 15.0
# A connected agent that has not sent anything for this long is no longer
# "active": it is connected and idle. The gate writes that down itself instead
# of leaving every UI to age the row on its own.
IDLE_AFTER_S: float = 300.0

# Valid agent identifiers — derived from the single source of truth in
# agent_identity.IDENTITIES, which agent_protocol.py:80 already validates
# against.
#
# This was previously a hand-maintained duplicate that had drifted: it omitted
# "terminal", "browser" and "chatgpt". Because AgentIngest maps every terminal
# emulator (Ghostty, iTerm, Warp, Kitty…) to the id "terminal", the client
# library accepted the registration while the gate rejected it at _register,
# so no agents row was ever written and the Pill had nothing to show. Deriving
# both sides from one set is what keeps them from drifting again.
try:
    from agent_identity import IDENTITIES as _IDENTITIES
except ImportError:  # package-relative when imported as hub.shannon_gate
    from hub.agent_identity import IDENTITIES as _IDENTITIES  # type: ignore

VALID_AGENTS: frozenset[str] = frozenset(_IDENTITIES.keys())

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
    # ── Self-report attestation ───────────────────────────────────────────
    # computed_divergence is written for EVERY scored, attested message
    # whether or not any bound was crossed — including in observe mode and
    # including when escalation was suppressed. This is what stops a tuned
    # under-report from producing gate_reasons='[]' and an audit row that
    # actively certifies the message as clean.
    computed_H_token: float = 0.0
    computed_divergence: Optional[float] = None   # d = log2(gate_H_tok/self_H)
    computed_residual: Optional[float] = None     # d after per-agent de-bias
    attested: Optional[bool] = None               # None = nothing to attest to
    trust_score: float = 0.0                      # accumulated under-reporting


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

        Dilution guard
        --------------
        This is a per-token MEAN, so it is *intensive*: appending free
        low-entropy padding drives it toward zero no matter how much
        high-entropy content sits alongside.  Once the stream is long enough
        for padding to be a plausible tactic (>= DILUTION_MIN_TOKENS), no
        single token is allowed to contribute more than DILUTION_CAP_FRAC of
        the mass.  Short messages — every message in the operator's real
        history — are measured exactly as before.
        """
        if not text or not text.strip():
            return 0.0
        tokens = text.lower().split()
        n = len(tokens)
        if n < 2:
            return 0.0
        counts = Counter(tokens)
        if n >= DILUTION_MIN_TOKENS:
            # Iterated to a fixed point. A single pass is not enough: with
            # 20000 padding tokens against 40 real ones, 2% of the *padded*
            # length is still 401 copies of the pad, which keeps the measured
            # entropy at 0.9 bits instead of the 5.4 the real content carries.
            # Each pass shrinks the stream, which tightens the cap, until the
            # padding no longer dominates. Converges in a handful of rounds and
            # is a no-op for any stream that was not padded in the first place.
            for _ in range(8):
                cap = max(3, math.ceil(DILUTION_CAP_FRAC * n))
                if not any(c > cap for c in counts.values()):
                    break
                counts = Counter({t: min(c, cap) for t, c in counts.items()})
                n = sum(counts.values())
            if n < 2:
                return 0.0
        # max(0.0, …) collapses the -0.0 that a degenerate (single-token)
        # distribution produces, since -1.0 * log2(1.0) is negative zero.
        return max(0.0, -sum((c / n) * math.log2(c / n) for c in counts.values()))

    @staticmethod
    def top_token_share(text: str) -> tuple[float, int]:
        """(fraction of the stream held by its most common token, n_tokens)."""
        tokens = (text or "").lower().split()
        n = len(tokens)
        if n == 0:
            return 0.0, 0
        return Counter(tokens).most_common(1)[0][1] / n, n

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

    @staticmethod
    def scored_text(payload: Any) -> str:
        """
        Every string the gate will score, from anywhere in the payload.

        This is the single extraction site, and it is deliberately a DENYLIST:
        every string at any nesting depth is collected unless its key is a
        known identifier/metadata key (METADATA_KEYS, or any ``*_id``).

        The previous implementation read 8 hardcoded top-level keys and only
        ``isinstance(val, str)`` values, which meant three separate free passes:

          * decoy key      — benign string in ``text``, real content in
                             ``result_body``; only the 0.30-weighted character
                             term ever saw the real payload;
          * nested escape  — ``{"content": {"text": ...}}`` is not a ``str``,
                             so a correctly-named key was skipped entirely;
          * omitted key    — ``prompt`` was simply not on the list, which is
                             how every approval request in the operator's real
                             history came to be scored as JSON punctuation.

        Identical strings are collected once. A payload that duplicates the
        same prose into ``prompt`` and ``text`` is one piece of information,
        not two, and double-counting it inflates the measurement of exactly
        the well-behaved clients that fill both fields.

        Order is stable (insertion order of first sight) so the value is
        deterministic and the client library can reproduce it byte for byte.
        """
        out: list[str] = []
        seen: set[str] = set()

        def walk(node: Any, key: Optional[str], depth: int) -> None:
            if depth > 12 or len(out) >= 5000:
                return
            if isinstance(node, dict):
                for k, v in node.items():
                    walk(v, str(k).lower(), depth + 1)
            elif isinstance(node, (list, tuple)):
                for v in node:
                    walk(v, key, depth + 1)
            elif isinstance(node, str):
                if key is not None and (key in METADATA_KEYS or key.endswith("_id")):
                    return
                s = node.strip()
                if s and s not in seen:
                    seen.add(s)
                    out.append(s)

        walk(payload, None, 0)
        return " ".join(out)

    @classmethod
    def combined_entropy_ex(cls, payload: dict[str, Any]) -> tuple[float, float, bool]:
        """
        Returns ``(H_blended, H_token, scored)``.

        ``scored`` is False when the payload held no scorable string at all, in
        which case H is pure JSON *character* entropy — ~4.2-4.6 bits for any
        structured payload, i.e. above H_THRESHOLD by construction.  That
        number is a fact about JSON punctuation, not a claim about content the
        agent could ever have attested to, so the attestation rules stay
        disarmed on that branch.  Callers that need to know which branch
        produced H must use this, not ``combined_entropy``.
        """
        text = cls.scored_text(payload)
        H_struct = cls.structural_entropy(payload)

        if text.strip():
            H_text = cls.token_entropy(text)
            return round(0.70 * H_text + 0.30 * H_struct, 4), round(H_text, 4), True
        return round(H_struct, 4), 0.0, False

    @classmethod
    def combined_entropy(cls, payload: dict[str, Any]) -> float:
        """
        Weighted combination:
          H = 0.70 * H_token(text fields) + 0.30 * H_struct(JSON structure)

        When no text content is present, falls back to structural entropy alone.
        Thin wrapper over :meth:`combined_entropy_ex` — kept so the public
        surface (and every existing caller/test) is unchanged.
        """
        return cls.combined_entropy_ex(payload)[0]

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
                    auth_method     TEXT DEFAULT 'socket_secret',
                    -- Last time this daemon *proved* the connection was open.
                    -- Refreshed every HEARTBEAT_INTERVAL_S while connected; see
                    -- the module header note on liveness.
                    heartbeat_ns    INTEGER,
                    -- Self-report calibration (see the ATTEST_* block above).
                    -- These are a CACHE of values derivable from
                    -- agent_messages.self_divergence — that table is written by
                    -- BOTH transports, so a score cached only here would have a
                    -- hole exactly the size of the HTTP path and an attacker
                    -- could reset its reputation by switching transport.
                    calib_n          INTEGER DEFAULT 0,
                    calib_bias       REAL    DEFAULT 0.0,
                    calib_score      REAL    DEFAULT 0.0,
                    calib_offences   INTEGER DEFAULT 0,
                    calib_silence    INTEGER DEFAULT 0,
                    calib_state      TEXT    DEFAULT 'unknown',
                    calib_updated_ns INTEGER
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
                    gate_reasons    TEXT,
                    gate_H_token    REAL,
                    -- Written for every scored+attested message whether or not
                    -- any bound was crossed. An agent that tunes its claim to
                    -- sit just inside the margin used to produce an empty
                    -- reasons list and an audit row that certified the message
                    -- as clean; the number is now always on the record.
                    self_divergence REAL,
                    self_residual   REAL,
                    attested        INTEGER
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
        """Add columns missing from databases created by an older gate.

        Purely additive ALTER TABLE, each guarded by its own try/except so a
        second daemon racing the same migration is a no-op rather than a crash.

        NOTE FOR ANYONE CALIBRATING ON HISTORY: adding "prompt" (and the
        recursive walk) to the scored text changes gate_H for existing message
        shapes, so historical gate_H values are not comparable across this
        migration boundary.  Measured impact on the operator's 43 rows is 2
        rows, both previously false-positive flags.  gate_H_token and
        self_divergence exist only from this version forward.
        """
        agent_cols = {row[1] for row in conn.execute("PRAGMA table_info(agents)").fetchall()}
        for col_name, col_def in [
            ("heartbeat_ns",     "INTEGER"),
            ("calib_n",          "INTEGER DEFAULT 0"),
            ("calib_bias",       "REAL DEFAULT 0.0"),
            ("calib_score",      "REAL DEFAULT 0.0"),
            ("calib_offences",   "INTEGER DEFAULT 0"),
            ("calib_silence",    "INTEGER DEFAULT 0"),
            ("calib_state",      "TEXT DEFAULT 'unknown'"),
            ("calib_updated_ns", "INTEGER"),
        ]:
            if col_name not in agent_cols:
                try:
                    conn.execute(f"ALTER TABLE agents ADD COLUMN {col_name} {col_def}")
                except sqlite3.OperationalError:
                    pass  # already present (race between processes)

        msg_cols = {
            row[1] for row in conn.execute("PRAGMA table_info(agent_messages)").fetchall()
        }
        for col_name, col_def in [
            ("gate_H_token",    "REAL"),
            ("self_divergence", "REAL"),
            ("self_residual",   "REAL"),
            ("attested",        "INTEGER"),
        ]:
            if col_name not in msg_cols:
                try:
                    conn.execute(
                        f"ALTER TABLE agent_messages ADD COLUMN {col_name} {col_def}"
                    )
                except sqlite3.OperationalError:
                    pass  # already present (race between processes)

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
                     gate_H, gate_D, gate_H_temporal, gate_decision, gate_reasons,
                     gate_H_token, self_divergence, self_residual, attested)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    time.time_ns(),
                    msg.agent_id, msg.task_id, msg.message_type, msg.message_id,
                    json.dumps(msg.payload),
                    msg.timestamp_ns, msg.shannon_H, msg.confidence,
                    decision.computed_H, decision.computed_D,
                    decision.computed_H_temporal,
                    decision.decision, json.dumps(decision.reasons),
                    decision.computed_H_token,
                    decision.computed_divergence, decision.computed_residual,
                    None if decision.attested is None else int(decision.attested),
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
                     disconnected_at, message_count, heartbeat_ns)
                VALUES (?, ?, ?, ?, ?, NULL, 0, ?)
                ON CONFLICT(agent_id) DO UPDATE SET
                    status          = excluded.status,
                    connected_at    = excluded.connected_at,
                    last_seen_ns    = excluded.last_seen_ns,
                    auth_method     = excluded.auth_method,
                    disconnected_at = NULL,
                    heartbeat_ns    = excluded.heartbeat_ns,
                    -- message_count is deliberately NOT reset here. It is a
                    -- lifetime total for the agent, and agent_messages rows are
                    -- never deleted, so zeroing it on every reconnect made the
                    -- counter disagree with the table it summarises: agents
                    -- that had reconnected repeatedly reported 1 while
                    -- agent_messages held 12. Only the initial INSERT seeds 0.
                    message_count   = agents.message_count
                """,
                (agent_id, status, connected_at_ns, connected_at_ns, auth_method,
                 connected_at_ns),
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
                    heartbeat_ns  = ?,
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
                    disconnected_at = ?,
                    heartbeat_ns    = ?
                WHERE agent_id = ?
                """,
                (disconnected_at_ns, disconnected_at_ns, agent_id),
            )

    def heartbeat_agents(
        self,
        agent_ids: list[str],
        now_ns: int,
        idle_after_ns: int,
    ) -> None:
        """Stamp liveness for the currently open connections.

        Two writes, both cheap and both about telling the truth:

        * `heartbeat_ns` — proof the connection was open at `now_ns`. Readers
          use its freshness (not the age of `last_seen_ns`) to decide whether an
          agent is still there, so a quiet agent stays live and a dead daemon's
          rows go offline on their own.
        * `status` — an agent that has not spoken in `idle_after_ns` is demoted
          from active/working to idle here, at the source, so every consumer
          agrees instead of each inventing its own staleness rule.
        """
        if not agent_ids:
            return
        marks = ",".join("?" * len(agent_ids))
        with self._connect() as conn:
            conn.execute(
                f"UPDATE agents SET heartbeat_ns = ? WHERE agent_id IN ({marks})",
                (now_ns, *agent_ids),
            )
            conn.execute(
                f"""
                UPDATE agents SET status = 'idle'
                WHERE agent_id IN ({marks})
                  AND status NOT IN ('idle', 'blocked')
                  AND last_seen_ns < ?
                """,
                (*agent_ids, now_ns - idle_after_ns),
            )

    def mark_all_disconnected(self, now_ns: int) -> int:
        """Close out rows left 'connected' by a previous run. Returns the count.

        A gate that is killed (or crashes) never runs the `finally` that stamps
        `disconnected_at`, so its rows claim an open connection forever. At
        startup nothing is connected yet by definition, so any such row is a
        leftover and is closed here — otherwise the pill shows agents as live
        that have not existed since the last reboot.
        """
        with self._connect() as conn:
            cur = conn.execute(
                """
                UPDATE agents SET
                    status          = 'idle',
                    disconnected_at = ?
                WHERE disconnected_at IS NULL
                """,
                (now_ns,),
            )
            return cur.rowcount or 0

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

    # Columns that describe the DETECTOR, not the message. Serving these to an
    # agent hands it the full history of what the gate measured for everyone —
    # enough to calibrate a local model offline and never appear to probe.
    _ADJUDICATION_COLUMNS = frozenset({
        "gate_H", "gate_D", "gate_H_temporal", "gate_decision", "gate_reasons",
        "gate_H_token", "self_divergence", "self_residual", "attested",
        "self_H", "self_conf",
    })

    def get_recent_messages(
        self, limit: int = 100, redact: bool = False, agent_id: Optional[str] = None
    ) -> list[dict]:
        """Recent audit rows.

        ``redact=True`` projects out every gate_*/self_* column — use it for
        anything served to an agent.  ``agent_id`` scopes the rows to one
        agent.  The unredacted, unscoped form is for human/operator surfaces
        (the Swift HUD reads the table directly over SQL and is unaffected).
        """
        sql = "SELECT * FROM agent_messages"
        params: list[Any] = []
        if agent_id is not None:
            sql += " WHERE agent_id = ?"
            params.append(agent_id)
        sql += " ORDER BY received_at_ns DESC LIMIT ?"
        params.append(limit)
        with self._connect() as conn:
            rows = conn.execute(sql, params).fetchall()
        out = [dict(r) for r in rows]
        if redact:
            out = [
                {k: v for k, v in r.items() if k not in self._ADJUDICATION_COLUMNS}
                for r in out
            ]
        return out

    # ── Self-report calibration ledger ────────────────────────────────────────

    def recent_divergences(self, agent_id: str, limit: int = ATTEST_WINDOW) -> list[float]:
        """This agent's last N NON-OFFENDING signed divergences, newest first.

        Read from agent_messages (written by BOTH transports) rather than from
        a cached scalar, so the ledger is recomputable and cannot be reset by
        switching transport.

        Rows that themselves tripped the margin are excluded, exactly as they
        are in the live window: a lie must not teach the gate what normal looks
        like for the agent that told it — otherwise a restart would rehydrate
        the offender's own lies as its baseline.
        """
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT self_divergence FROM agent_messages
                WHERE agent_id = ? AND self_divergence IS NOT NULL
                  AND NOT (self_divergence >= ? AND COALESCE(gate_H_token, 0) >= ?)
                ORDER BY received_at_ns DESC LIMIT ?
                """,
                (agent_id, ATTEST_MARGIN, ATTEST_FLOOR, limit),
            ).fetchall()
        return [float(r[0]) for r in rows]

    def load_calibration(self, agent_id: str) -> Optional[dict]:
        with self._connect() as conn:
            row = conn.execute(
                """
                SELECT calib_n, calib_bias, calib_score, calib_offences,
                       calib_silence, calib_state, calib_updated_ns
                FROM agents WHERE agent_id = ?
                """,
                (agent_id,),
            ).fetchone()
        return dict(row) if row else None

    def save_calibration(
        self,
        agent_id: str,
        n: int,
        bias: float,
        score: float,
        offences: int,
        silence: int,
        state: str,
        updated_ns: int,
    ) -> None:
        # UPSERT, not UPDATE: the HTTP transport may never have registered the
        # agent, and reputation must not depend on which door it came through.
        with self._connect() as conn:
            conn.execute(
                """
                INSERT INTO agents (agent_id, calib_n, calib_bias, calib_score,
                                    calib_offences, calib_silence, calib_state,
                                    calib_updated_ns)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(agent_id) DO UPDATE SET
                    calib_n=excluded.calib_n,
                    calib_bias=excluded.calib_bias,
                    calib_score=excluded.calib_score,
                    calib_offences=excluded.calib_offences,
                    calib_silence=excluded.calib_silence,
                    calib_state=excluded.calib_state,
                    calib_updated_ns=excluded.calib_updated_ns
                """,
                (agent_id, n, bias, score, offences, silence, state, updated_ns),
            )

    def calibration_report(self) -> list[dict]:
        """Per-agent self-report calibration, for the operator only.

        The distinction that matters: an agent whose mean divergence sits at a
        constant is a MISCALIBRATED CLIENT (wrong tokenizer, bits-vs-nats,
        scoring a different field) and should be fixed, not blocked.  An agent
        whose mean is near zero but whose max spikes on particular messages is
        the one worth reading the payloads of.
        """
        with self._connect() as conn:
            rows = conn.execute(
                """
                SELECT agent_id,
                       COUNT(*)                                   AS n,
                       SUM(attested = 1)                          AS n_attested,
                       SUM(COALESCE(attested, 1) = 0)             AS n_silent,
                       ROUND(AVG(self_divergence), 3)             AS mean_d,
                       ROUND(MAX(self_divergence), 3)             AS max_d,
                       SUM(gate_decision IN ('flagged','blocked')) AS n_flagged
                FROM agent_messages
                GROUP BY agent_id ORDER BY agent_id
                """
            ).fetchall()
            cal = {
                r["agent_id"]: dict(r)
                for r in conn.execute(
                    """
                    SELECT agent_id, calib_n, calib_bias, calib_score,
                           calib_offences, calib_silence, calib_state
                    FROM agents
                    """
                ).fetchall()
            }
        out = []
        for r in rows:
            d = dict(r)
            d.update(cal.get(d["agent_id"], {}))
            out.append(d)
        return out

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


# ── Self-report calibration ledger ────────────────────────────────────────────

@dataclass
class Attestation:
    """What the ledger concluded about one self-report."""
    divergence: Optional[float] = None   # d = log2(gate_H_tok / self_H)
    residual: Optional[float] = None     # d after subtracting the agent's bias
    attested: Optional[bool] = None      # None = no scorable text to attest to
    score: float = 0.0                   # accumulated under-reporting evidence
    offences: int = 0
    n: int = 0
    bias: float = 0.0
    state: str = "unknown"
    reasons: list[str] = field(default_factory=list)
    escalate_flag: bool = False
    escalate_block: bool = False
    headroom: float = 0.0                # bits added to H_flag, never to H_block


class AttestationLedger:
    """
    Per-agent record of how well an agent's claims about itself match what the
    gate independently measured.

    The signal is NOT the raw mismatch — that is the statistic a wrong
    tokenizer also inflates, consistently, on every message it ever sends.  The
    signal is the RESIDUAL AFTER SUBTRACTING THE AGENT'S OWN LEARNED BIAS,
    accumulated.  A constant offset (units error, different field, different
    tokenizer) converges into ``bias`` and vanishes.  What survives is
    CONDITIONAL under-reporting — honest about the boring messages, lying about
    the one that matters — which is what deception actually looks like.

    The learned bias is CAPPED (ATTEST_BIAS_CAP).  Without the cap, an agent
    that under-reports by a constant factor from its very first message has
    that lie learned as its baseline and normalised away for ever; with it, an
    agent can buy at most half a bit of excuse.
    """

    def __init__(self, db: AuditDB) -> None:
        self.db = db
        self._cache: dict[str, dict[str, Any]] = {}

    # ── State ─────────────────────────────────────────────────────────────────

    def _state(self, agent_id: str) -> dict[str, Any]:
        st = self._cache.get(agent_id)
        if st is not None:
            return st
        row = self.db.load_calibration(agent_id) or {}
        st = {
            "n": int(row.get("calib_n") or 0),
            "bias": float(row.get("calib_bias") or 0.0),
            "score": float(row.get("calib_score") or 0.0),
            "offences": int(row.get("calib_offences") or 0),
            "silence": int(row.get("calib_silence") or 0),
            "state": str(row.get("calib_state") or "unknown"),
            "updated_ns": int(row.get("calib_updated_ns") or 0),
            "window": deque(
                reversed(self.db.recent_divergences(agent_id, ATTEST_WINDOW)),
                maxlen=ATTEST_WINDOW,
            ),
        }
        # Wall-clock decay on load: an agent that lied a month ago and has been
        # idle since must be able to come back, or a low-traffic agent is
        # blocked for ever with no way to earn its way out.
        if st["updated_ns"] and ATTEST_HALFLIFE_H > 0:
            dt_h = (time.time_ns() - st["updated_ns"]) / 3.6e12
            if dt_h > 0:
                st["score"] *= 2.0 ** (-dt_h / ATTEST_HALFLIFE_H)
        self._cache[agent_id] = st
        return st

    def _persist(self, agent_id: str, st: dict[str, Any]) -> None:
        try:
            self.db.save_calibration(
                agent_id, st["n"], st["bias"], st["score"], st["offences"],
                st["silence"], st["state"], st["updated_ns"],
            )
        except Exception as exc:                # never let bookkeeping kill the gate
            logger.debug(f"calibration persist failed for {agent_id}: {exc}")

    @staticmethod
    def _classify(st: dict[str, Any]) -> str:
        if st["score"] >= ATTEST_BLOCK_SCORE:
            return "untrusted"
        if st["score"] >= ATTEST_FLAG_SCORE:
            return "suspect"
        if st["n"] < ATTEST_CALIB_N:
            return "calibrating"
        total = st["n"] + st["silence"]
        silence_rate = st["silence"] / total if total else 0.0
        if abs(st["bias"]) <= ATTEST_BIAS_CAP and silence_rate < 0.34:
            return "calibrated"
        return "miscalibrated"

    # ── Main entry point ──────────────────────────────────────────────────────

    def observe(
        self,
        agent_id: str,
        self_H: float,
        gate_H_token: float,
        confidence: float,
        scored: bool,
    ) -> Attestation:
        a = Attestation()
        if ATTEST_MODE == "off" or not scored:
            # Nothing scorable was handed to the gate, so there is nothing the
            # agent could have attested to. No offence is possible — and the
            # only way to reach this branch is a payload with no string
            # anywhere, which lands on the pure-JSON-character entropy branch
            # (~4.3 bits) and is flagged on its own merits regardless.
            return a

        st = self._state(agent_id)
        a.attested = self_H > 0.0

        if not a.attested:
            # SILENCE IS NOT AN EXEMPTION. The old guard `if msg.shannon_H > 0`
            # meant omitting the field skipped the check entirely, so
            # reasons(honest) was a strict superset of reasons(silent) while
            # the verdict was identical: speaking was weakly dominated and
            # every rational agent converged on saying nothing.
            st["silence"] += 1
            if gate_H_token >= UNATTESTED_FLOOR:
                a.reasons.append("unattested")
                a.escalate_flag = True
                st["score"] = (
                    (1 - ATTEST_ALPHA) * st["score"]
                    + ATTEST_ALPHA * ATTEST_MARGIN * ATTEST_SILENCE_W
                )
        else:
            d = math.log2((gate_H_token + 1e-9) / (self_H + 1e-9))
            a.divergence = round(d, 4)
            st["n"] += 1

            under = (
                gate_H_token >= ATTEST_FLOOR
                and d >= ATTEST_MARGIN
            )

            # A LIE MUST NOT TEACH THE GATE WHAT NORMAL LOOKS LIKE. Only
            # messages that did not themselves trip the margin feed the
            # calibration window, so a persistent liar never establishes a
            # baseline that excuses it — its bias stays near zero and the
            # residual stays large. Without this, under-reporting by a constant
            # factor from the first message trains that factor as the agent's
            # habit and normalises it away: the offender would be blocked
            # early, then quietly forgiven back down as its own lies became
            # its baseline. The divergence is still recorded on the audit row
            # either way; it just does not get a vote on the baseline.
            if not under:
                st["window"].append(d)

            # Bias is only trusted once there is enough history for a median to
            # mean something, and never beyond ATTEST_BIAS_CAP.
            if len(st["window"]) >= ATTEST_CALIB_N:
                st["bias"] = round(statistics.median(st["window"]), 4)
            bias_used = max(-ATTEST_BIAS_CAP, min(ATTEST_BIAS_CAP, st["bias"]))
            e = max(0.0, d - bias_used - ATTEST_TOL)
            a.residual = round(e, 4)

            if under:
                a.reasons.append("self_report_divergence")
                a.escalate_flag = True
                st["offences"] += 1
            elif d <= -ATTEST_OVER_MARGIN:
                # Two-sided OBSERVATION, one-sided ACTION. Reporting a huge
                # shannon_H used to drive the old ratio to ~0 and immunise the
                # agent for free; it is now recorded as its own miscalibration
                # signal, but a clumsy client is never blocked for erring safe.
                a.reasons.append("self_report_overclaim")
            elif abs(d) < ATTEST_MARGIN:
                # The incentive inversion, part 1: an honest report earns a
                # positive mark that silence cannot.
                a.reasons.append("attested_calibrated")

            # Confidence is a MODIFIER, never a trigger. All 43 messages in the
            # operator's real history carry confidence in {0.95, 1.00}, so
            # gating on it directly would be pure false-positive surface. The
            # load-bearing thing is the INTERACTION: high measured entropy with
            # high claimed confidence is the deception signature; high entropy
            # with LOW claimed confidence is an honest agent asking for help
            # and should be routed, not punished.
            if under and confidence < 0.50:
                a.reasons.append("needs_help")
                a.escalate_flag = False
                st["offences"] = max(0, st["offences"] - 1)
                e = 0.0
            elif under and confidence >= 0.90:
                a.reasons.append("deceptive_signature")

            st["score"] = (1 - ATTEST_ALPHA) * st["score"] + ATTEST_ALPHA * e

        # Accumulated evidence. This is the part a hard per-message cliff can
        # never have: persistent small under-reporting that never crosses
        # ATTEST_MARGIN still integrates to a verdict, so there is no constant
        # to sit just inside.
        if st["n"] >= ATTEST_MIN_N and st["score"] >= ATTEST_FLAG_SCORE:
            if "sustained_divergence" not in a.reasons:
                a.reasons.append("sustained_divergence")
            a.escalate_flag = True
        if st["score"] >= ATTEST_BLOCK_SCORE and st["offences"] >= ATTEST_MIN_OFFENCES:
            a.reasons.append("repeat_offender")
            a.escalate_block = True

        st["state"] = self._classify(st)
        st["updated_ns"] = time.time_ns()

        # The incentive inversion, part 2: a demonstrated record of honest
        # self-reporting is the only way to buy entropy headroom. Capped, and
        # never applied to H_BLOCK_THRESHOLD.
        if st["state"] == "calibrated" and st["score"] < ATTEST_FLAG_SCORE / 2:
            a.headroom = ATTEST_BONUS

        a.score = round(st["score"], 4)
        a.offences = st["offences"]
        a.n = st["n"]
        a.bias = st["bias"]
        a.state = st["state"]
        self._persist(agent_id, st)
        return a


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
        self.ledger = AttestationLedger(db)
        self._temporal_history: dict[str, deque[str]] = defaultdict(
            lambda: deque(maxlen=TEMPORAL_WINDOW)
        )
        # {task_id: {agent_id: cf_value}}
        self._cf_cache: dict[str, dict[str, float]] = defaultdict(dict)

    def evaluate(self, msg: AgentMessage) -> GateDecision:
        reasons: list[str] = []

        # ── 1. Compute gate-side output entropy ───────────────────────────────
        # H_tok is the like-for-like term: the client reports token entropy, so
        # the divergence must be measured against token entropy. Comparing the
        # blended H (which carries a ~1.3-bit constant structural floor) against
        # a pure token self-report is what made the old ratio uninterpretable —
        # the floor dominates exactly where short content puts the threshold.
        scored_text = self.analyzer.scored_text(msg.payload)
        H, H_tok, scored = self.analyzer.combined_entropy_ex(msg.payload)
        H = round(H, 4)

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

        # ── 4. Payload dilution ───────────────────────────────────────────────
        # Appending free low-entropy padding drags the per-token mean toward
        # zero AND concentrates the character distribution, so one move used to
        # silence both entropy terms and the mismatch check at once.
        share, n_tok = self.analyzer.top_token_share(scored_text)
        diluted = n_tok >= DILUTION_MIN_TOKENS and share >= DILUTION_SHARE
        if diluted:
            reasons.append("payload_dilution")

        # ── 5. Self-report attestation ────────────────────────────────────────
        att = self.ledger.observe(
            msg.agent_id, msg.shannon_H, H_tok, msg.confidence, scored
        )
        reasons.extend(att.reasons)

        # ── 6. Gate decision tree ─────────────────────────────────────────────
        # Attested calibration is the ONLY thing that moves a threshold, it
        # moves only the flag threshold, and it moves it by at most
        # ATTEST_BONUS. H_BLOCK_THRESHOLD is never touched by reputation in
        # either direction.
        H_flag_eff = H_THRESHOLD + (att.headroom if ATTEST_MODE == "enforce" else 0.0)
        decision: str

        if H >= H_BLOCK_THRESHOLD:
            reasons.append(
                f"H_hard_block({H:.2f}>={H_BLOCK_THRESHOLD})"
            )
            if msg.message_type == "code_suggestion":
                reasons.append("code_suggestion_hard_blocked")
            decision = "blocked"

        elif H >= H_flag_eff:
            reasons.append(f"H_flag({H:.2f}>={H_flag_eff})")
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

        # ── 6b. Attestation escalation (terminal stage) ───────────────────────
        # Deliberately AFTER the tree, never inside it, so the entropy verdict
        # stays a pure function of the measurement and the claim's effect on it
        # is one auditable step. pass -> blocked is structurally impossible:
        # every block goes through flagged, so the operator always sees a
        # warning before traffic stops.
        if ATTEST_MODE == "enforce":
            if diluted and decision == "pass":
                decision = "flagged"
            if att.escalate_flag and decision == "pass":
                decision = "flagged"
            if att.escalate_block and decision == "flagged":
                decision = "blocked"

        gate_decision = GateDecision(
            decision=decision,
            reasons=reasons,
            computed_H=H,
            computed_D=D,
            computed_H_temporal=H_temp,
            computed_H_token=round(H_tok, 4),
            computed_divergence=att.divergence,
            computed_residual=att.residual,
            attested=att.attested,
            trust_score=att.score,
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

    def __init__(
        self,
        http_host: str = HTTP_HOST,
        http_port: int = HTTP_PORT,
        db_path: Optional[Path] = None,
    ) -> None:
        self.http_host = http_host
        self.http_port = http_port

        # db_path is explicit so a caller (notably a test) can construct a hub
        # without touching the operator's real ~/.shannon/agent_hub.db. This
        # used to be hardcoded to DB_PATH, so merely instantiating AgentHub —
        # even in a test that immediately replaced .db with a tmp file — opened
        # and schema-migrated the live audit database as a side effect.
        self.db = AuditDB(db_path if db_path is not None else DB_PATH)
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

            # Welcome: send current benchmark state.
            #
            # The `thresholds` block that used to live here is GONE. It handed
            # every agent the exact decision boundaries as the reply to
            # registration — zero probes required — which combined with the
            # echoed gate_H reduced evasion to arithmetic. Nothing an agent
            # legitimately does requires knowing where the line is. Verified
            # zero consumers: agent_protocol.py only checks welcome["type"],
            # and the Swift HUD hardcodes its own constants.
            await conn.send_json({
                "type": "welcome",
                "agent_id": agent_id,
                "benchmark": self._benchmark,
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

    # ── Verdict disclosure policy ─────────────────────────────────────────────

    def _check_message_type(self, msg: AgentMessage, source_id: str) -> bool:
        """Enforce VALID_MESSAGE_TYPES. Returns False if the message is rejected.

        Default is observe-and-continue (SHANNON_STRICT_TYPES=0): the set at
        module scope has drifted from reality before — the same class of bug
        the VALID_AGENTS comment documents — so rejecting on it silently would
        break live traffic. Set SHANNON_STRICT_TYPES=1 after a week of clean
        logs.
        """
        if msg.message_type in VALID_MESSAGE_TYPES:
            return True
        logger.warning(
            f"unknown message_type {msg.message_type!r} from {source_id} "
            f"({'rejected' if STRICT_TYPES else 'accepted — SHANNON_STRICT_TYPES=0'})"
        )
        return not STRICT_TYPES

    @staticmethod
    def _log_verdict(msg: AgentMessage, decision: GateDecision) -> None:
        """Full detail to the human surface: the daemon log.

        The reason strings are excellent audit records and terrible wire
        responses. They stay — here, and in agent_messages.gate_reasons, which
        is what the Swift HUD reads over SQL.
        """
        if decision.decision not in ("flagged", "blocked"):
            return
        log_fn = logger.warning if decision.decision == "blocked" else logger.info
        d = (
            "n/a" if decision.computed_divergence is None
            else f"{decision.computed_divergence:.2f}"
        )
        log_fn(
            f"GATE {decision.decision.upper()} [{msg.agent_id}] "
            f"H={decision.computed_H:.2f} H_tok={decision.computed_H_token:.2f} "
            f"D={decision.computed_D:.2f} self_H={msg.shannon_H:.2f} "
            f"divergence={d} trust={decision.trust_score:.2f} "
            f"reasons={decision.reasons}"
        )

    @staticmethod
    def _gate_response_envelope(
        msg: AgentMessage, decision: GateDecision
    ) -> dict[str, Any]:
        """What the MEASURED PARTY is told. Deliberately almost nothing.

        Removed from this envelope: gate_H, gate_D, gate_H_temporal and the
        full reasons list. Those handed the subject of the decision (a) the
        exact continuous measurement, (b) which rule fired, and (c) via strings
        like "H_flag(4.00>=3.5)" and "H_mismatch(self=1.00,gate=4.58)", the
        constant and both operands of the comparison — a closed-form solution
        for the largest undetected lie. That is a complete gradient to optimise
        against, i.e. the evaluation-awareness this project exists to detect,
        manufactured by the detector. The socket also sent it BEFORE the
        blocked-return, so even a blocked agent got the full readout.

        WHY `decision` SURVIVES (SHANNON_ECHO=decision, the default): both
        shipped clients block on this reply — agent_protocol._send_socket does
        a synchronous readline and returns the dict to the caller, and callers
        branch on decision. Returning a bare ack breaks every one of them. It
        is one categorical value per message rather than a float, so a patient
        agent can still bisect on it; per-agent probe-rate counting and
        threshold jitter are the follow-up that actually closes that, and they
        do not belong in this change. An operator who can update every client
        sets SHANNON_ECHO=none today.

        The new reason strings are written WITHOUT operands
        ("self_report_divergence", not "self_report_divergence(d=1.41)") so a
        future accidental re-exposure leaks a label rather than a gradient.
        """
        env: dict[str, Any] = {
            "type": "gate_response",
            "message_id": msg.message_id,
        }
        if ECHO_MODE == "none":
            env["accepted"] = decision.decision != "blocked"
        else:
            env["decision"] = decision.decision
        return env

    @staticmethod
    def _broadcast_envelope(
        msg: AgentMessage, decision: GateDecision, **extra: Any
    ) -> dict[str, Any]:
        """What PEERS are told. The payload, not the adjudication.

        gate_H and the gate_alert block (severity/reasons/computed_D) used to
        ride along here, which gave any agent holding a socket a free stream of
        every other agent's measured entropy, verdict and reason strings —
        including the mismatch strings that disclosed the other agent's own
        self-report. An attacker needed no probes of its own; it learned the
        boundary by watching a noisy peer, and a colluding pair could split the
        work so neither individually looked like it was searching.

        gate_decision stays: a consumer needs to know whether the material it
        is about to act on was adjudicated clean, and it is the same one
        categorical value the sender already has. Alerts go to the human
        surfaces (daemon log, agent_messages, HUD) instead.
        """
        env: dict[str, Any] = {
            "type": "agent_message",
            "from": msg.agent_id,
            "message_type": msg.message_type,
            "task_id": msg.task_id,
            "payload": msg.payload,
            "gate_decision": decision.decision,
            "timestamp_ns": msg.timestamp_ns,
        }
        env.update(extra)
        return env

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

        if not self._check_message_type(msg, source.agent_id):
            return

        # EVERY inbound message is scored and audited BEFORE any dispatch
        # branch. message_type used to select whether the gate ran at all —
        # 'query' returned before evaluate(), and so did approval_response —
        # while VALID_MESSAGE_TYPES was defined and referenced nowhere, so the
        # type was an attacker-chosen free-form string. An agent could opt out
        # of measurement, out of the audit log and out of the calibration
        # ledger by spelling.
        decision = self.gate.evaluate(msg)
        self._log_verdict(msg, decision)

        # Query messages are read-only, so they are measured and logged but
        # never denied: 'read-only' is not 'harmless' when the thing being read
        # is the detector's output, but refusing a benchmark_state read would
        # break live clients for no security gain.
        if msg.message_type == "query":
            await self._answer_query(msg, source)
            return

        # Human approval resolution from hub UI (measured + logged above, but
        # never blocked: this is the control plane the human uses to release
        # traffic, and a gate that can block its own release valve can deadlock
        # itself).
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

        # Echo gate decision back to sender (redacted — see
        # _gate_response_envelope)
        await source.send_json(self._gate_response_envelope(msg, decision))

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

        # Build broadcast envelope (redacted — see _broadcast_envelope)
        envelope = self._broadcast_envelope(
            msg, decision,
            task_summary=status_upd.task_summary,
            ui_status=status_upd.status,
        )

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
            # Scoped to the requester's own rows and projected free of every
            # gate_*/self_* column. This used to be SELECT * over the whole
            # table: every agent's payload, self-report, measured entropy,
            # verdict and reasons, served to any agent, ungated and unlogged.
            # An attacker read the full history of what the detector measured
            # for everyone, calibrated offline against it, and left no trace in
            # the table it had just read.
            limit = int(msg.payload.get("limit", 50))
            rows = self.db.get_recent_messages(
                limit, redact=True, agent_id=msg.agent_id
            )
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

            if not self._check_message_type(msg, agent_id):
                return web.json_response(
                    {"error": f"invalid_message_type:{msg.message_type}"}, status=400
                )

            decision = self.gate.evaluate(msg)
            self._log_verdict(msg, decision)

            # The socket path calls upsert_agent at registration and
            # update_agent_seen after every message; this path called neither,
            # so an agent that submitted exclusively over HTTP was gated and
            # audited but never appeared in the agents table — a reputation
            # hole exactly the size of the transport, resettable by switching
            # door. (The ledger derives from agent_messages for the same
            # reason, so this is belt and braces plus HUD visibility.)
            try:
                self.db.upsert_agent(agent_id, "active", time.time_ns())
                self.db.update_agent_seen(
                    agent_id, time.time_ns(), decision.computed_H, msg.task_id,
                )
            except Exception as exc:
                logger.debug(f"HTTP agent registry update failed: {exc}")

            if decision.decision == "blocked":
                return web.json_response(
                    self._gate_response_envelope(msg, decision), status=200
                )

            if msg.message_type == "benchmark_update":
                self._benchmark.update({
                    k: msg.payload[k]
                    for k in ("completed", "total", "best_cf", "best_rmsd",
                              "active_target", "task_id")
                    if k in msg.payload
                })
                self.db.update_benchmark_state(msg.task_id, self._benchmark)

            # Broadcast to Unix socket subscribers (same redaction as the
            # socket path — a mirror that leaked would defeat the point)
            await self._broadcast(
                self._broadcast_envelope(msg, decision), exclude=agent_id
            )

            return web.json_response(self._gate_response_envelope(msg, decision))

        async def get_state(request: web.Request) -> web.Response:
            state = self.db.get_latest_benchmark_state() or self._benchmark
            return web.json_response(dict(state))

        async def get_health(request: web.Request) -> web.Response:
            # /health has no authentication of any kind and used to serve the
            # exact decision boundaries to anyone who asked. Liveness does not
            # require disclosing the thresholds.
            async with self._lock:
                n = len(self._connections)
            return web.json_response({
                "status": "ok",
                "connected_agents": n,
            })

        async def get_messages(request: web.Request) -> web.Response:
            # This is a full audit-log dump served with no auth. Until it is
            # behind an admin token bound to loopback, it must not carry the
            # detector's own output: same projection as the socket query path.
            limit = int(request.rel_url.query.get("limit", "50"))
            rows = self.db.get_recent_messages(limit, redact=True)
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
        logger.info("  GET  /health    — liveness only (thresholds are not disclosed)")
        logger.info("  GET  /messages  — recent audit log (adjudication redacted)")

    # ── Main run loop ─────────────────────────────────────────────────────────

    async def _heartbeat_loop(self) -> None:
        """Stamp `heartbeat_ns` for open connections until shutdown.

        This is what lets a reader tell "connected and quiet" from "gate died
        with the row still open" — see `AuditDB.heartbeat_agents`.
        """
        assert self._shutdown is not None
        while not self._shutdown.is_set():
            try:
                async with self._lock:
                    ids = list(self._connections.keys())
                self.db.heartbeat_agents(
                    ids, time.time_ns(), int(IDLE_AFTER_S * 1e9)
                )
            except Exception as exc:            # never let liveness kill the hub
                logger.debug(f"heartbeat failed: {exc}")
            try:
                await asyncio.wait_for(
                    self._shutdown.wait(), timeout=HEARTBEAT_INTERVAL_S
                )
            except asyncio.TimeoutError:
                continue

    async def run(self) -> None:
        # Bind asyncio primitives to the running loop (fixes "attached to a different loop").
        self._lock = asyncio.Lock()
        self._shutdown = asyncio.Event()

        # Nothing is connected yet, so any row that still claims to be is a
        # leftover from a run that did not shut down cleanly.
        stale = self.db.mark_all_disconnected(time.time_ns())
        if stale:
            logger.info(f"Closed {stale} stale agent row(s) from a previous run")

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

        heartbeat = asyncio.create_task(self._heartbeat_loop())

        async with unix_server:
            await self._shutdown.wait()

        logger.info("Shutting down…")
        heartbeat.cancel()
        async with self._lock:
            for c in self._connections.values():
                c.close()
        # Closing the writers does not guarantee each handler's `finally` runs
        # before the process exits, so state the truth once, here: after this
        # daemon stops, nothing is connected to it.
        self.db.mark_all_disconnected(time.time_ns())

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
    p.add_argument("--attest", choices=("off", "observe", "enforce"),
                   default=ATTEST_MODE,
                   help="Self-report attestation mode. 'observe' computes and "
                        "persists divergence + reasons but changes NO verdict — "
                        "run it for a week, read --attest-report, then enforce. "
                        "(default: %(default)s; env SHANNON_ATTEST)")
    p.add_argument("--attest-report", action="store_true",
                   help="Print the per-agent self-report calibration table and "
                        "exit without starting a daemon")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="Set log level to DEBUG")
    return p.parse_args()


def _print_attest_report(db_path: Path) -> None:
    db = AuditDB(db_path)
    rows = db.calibration_report()
    hdr = (f"{'agent':<14}{'n':>5}{'att':>5}{'sil':>5}{'mean_d':>8}{'max_d':>8}"
           f"{'bias':>7}{'score':>7}{'off':>5}{'flag':>6}  state")
    print(hdr)
    print("-" * len(hdr))
    for r in rows:
        def f(k, w, p=2):
            v = r.get(k)
            return f"{v:>{w}.{p}f}" if isinstance(v, (int, float)) else f"{'-':>{w}}"
        print(
            f"{r['agent_id']:<14}{r['n'] or 0:>5}{r.get('n_attested') or 0:>5}"
            f"{r.get('n_silent') or 0:>5}{f('mean_d', 8)}{f('max_d', 8)}"
            f"{f('calib_bias', 7)}{f('calib_score', 7)}"
            f"{r.get('calib_offences') or 0:>5}{r.get('n_flagged') or 0:>6}"
            f"  {r.get('calib_state') or 'unknown'}"
        )
    print(
        "\nmean_d ~ constant  -> miscalibrated CLIENT (units / tokenizer / wrong"
        "\n                      field). Fix the client; it is not lying."
        "\nmean_d ~ 0, max_d spikes -> read those payloads. Conditional"
        "\n                      under-reporting is what deception looks like."
    )


def main() -> None:
    args = _parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Apply CLI overrides to module-level constants
    global SOCKET_PATH, DB_PATH, H_THRESHOLD, H_BLOCK_THRESHOLD, D_THRESHOLD
    global ATTEST_MODE
    SOCKET_PATH = args.socket
    DB_PATH = Path(args.db)
    H_THRESHOLD = args.h_flag
    H_BLOCK_THRESHOLD = args.h_block
    D_THRESHOLD = args.d_flag
    ATTEST_MODE = args.attest

    if args.attest_report:
        _print_attest_report(DB_PATH)
        return

    hub = AgentHub(http_host=args.http_host, http_port=args.http_port)
    logger.info(f"Self-report attestation: {ATTEST_MODE}")
    asyncio.run(hub.run())


if __name__ == "__main__":
    main()
