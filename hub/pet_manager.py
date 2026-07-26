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
  python pet_manager.py mood <agent_id>
  python pet_manager.py motion <agent_id> [--presence live] [--status active] …
  python pet_manager.py package [pet_id]   # resolve Codex v2 atlas package
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
import re
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
    "claude_code", "cowork", "dispatch", "science", "design",
    "grok_build", "codex", "dataset_runner",
]

# ── Mood derivation ───────────────────────────────────────────────────────────
#
# The durable counterpart to the Swift HUD's frame-level mood
# (PillCore.CompanionMood): a coarse label computed from what actually persisted
# to disk.
#
#   celebrating  → a recent turn ended well                    (Swift .happy)
#   focused      → agent is provably active on a turn right now (Swift .alert)
#   grinding     → agent is provably mid-task, a long resumable run
#   watching     → this record is a ⌘D *observation* of a frontmost app
#   resting      → idle, but seen recently                      (Swift .idle)
#   sleeping     → idle and untouched for a while               (Swift .sleepy)
#
# THE HONESTY RULE. `~/.shannon/pets/{agent}/state.json` is not telemetry. ⌘D
# writes it from whichever macOS app happened to be frontmost, and nothing ever
# writes the status back down — there are records on this machine still claiming
# `"status": "active"` from two days ago. `AgentIngest.PetBootstrap` now writes
# `"status": "observed", "source": "observed"` for exactly that reason.
#
# So only `focused` and `grinding` — the two labels in MOOD_CLAIMS_WORK — assert
# that work is happening, and both require the record to be (a) not an
# observation and (b) provably fresher than LIVE_WINDOW. Everything older
# degrades to `sleeping`, which is what the pre-fix records on disk correctly
# resolve to. A record with no usable `updated_at` is of *unknown* age: it is
# neither current nor stale, so it rests — an absent timestamp is never read as
# "seen just now". The gate (agent_hub.db) remains the only authority on
# liveness; this function never upgrades a pet record into a liveness claim.
#
# OBSERVATION LIFECYCLE. `observed` is a property of one snapshot, not a
# permanent brand on the pet. A ⌘D capture marks the record so it cannot claim
# work, but the very next write of *real* agent telemetry (`on_agent_turn_start`
# / `on_agent_turn_end`, or any caller that goes through
# `PetState.mark_agent_telemetry`) supersedes that provenance with
# `source = SOURCE_AGENT`. Without this, an agent captured once by ⌘D could
# never again read as focused/grinding, no matter what it actually did.

CELEBRATE_WINDOW: float = 60.0    # seconds a good finish still reads as a win
LIVE_WINDOW:      float = 90.0    # a status claim older than this is not current
MOOD_SLEEP_AFTER: float = 300.0   # seconds idle before a pet is "sleeping"
CLOCK_SKEW_GRACE: float = 5.0     # tolerated write-vs-read clock jitter

#: The only moods that assert the agent is doing work. Mirrors
#: `CompanionMood.claimsWork` on the Swift side.
MOOD_CLAIMS_WORK = frozenset({"focused", "grinding"})

#: Values of `state.source` / `state.status` that mark a record as a ⌘D capture
#: rather than agent telemetry.
OBSERVED_MARKERS = frozenset({"observed", "cmd_d"})

#: `state.source` written by real agent telemetry. Supersedes an earlier ⌘D
#: observation on the same record — see the observation lifecycle above.
SOURCE_AGENT = "agent"

# ── Turn-outcome classification ──────────────────────────────────────────────
#
# `celebrating` is the one mood driven by free text, so the match has to be
# robust: bare substring containment made every failure phrasing that happens
# to embed a success stem read as a win ("incomplete" ⊃ "complete",
# "unsuccessful" ⊃ "success"). Matching is therefore token-based (word
# boundaries, so prefixed forms cannot match), with three extra guards:
#   * any explicit failure token vetoes the whole string ("completion failed"),
#     including hyphen-split spellings ("un-successful", "in-complete"), unless
#     that failure token is itself negated or zeroed ("0 failures", "no errors"),
#   * a negation *anywhere earlier in the same clause* cancels a success token
#     ("did not pass", "not a single test passed", "none of the targets
#     solved") — a fixed-width lookback is not enough, because the negation and
#     the success stem can be arbitrarily far apart, and
#   * clauses are scored independently, so a negation cannot leak across a
#     boundary and suppress a genuine win ("no regressions, all targets
#     solved").

_TOKEN_RE = re.compile(r"[a-z0-9]+")

#: Clause boundaries. A negation binds only within its own clause.
_CLAUSE_SPLIT_RE = re.compile(
    r"[.,;:!?/()\[\]{}\n]+|\b(?:but|however|although|though|yet|while|and|then)\b"
)

#: Hyphen/underscore *inside* a word — removed for the failure veto so that
#: "un-successful" is seen as the failure token "unsuccessful".
_INWORD_JOIN_RE = re.compile(r"(?<=[a-z0-9])[-_]+(?=[a-z0-9])")

#: Whole tokens (inflections listed explicitly) that assert a good finish.
_SUCCESS_TOKENS = frozenset({
    "success", "successes", "successful", "successfully",
    "succeed", "succeeded", "succeeds",
    "complete", "completed", "completes", "completing", "completion",
    "pass", "passed", "passes", "passing",
    "record", "records", "recorded",
    "solve", "solved", "solves",
})

#: Tokens that flip the meaning of a success token later in the same clause.
#: Zero quantifiers count: "0 tests passed" is not a win, and symmetrically
#: "0 failures" is not a failure.
_NEGATION_TOKENS = frozenset({
    "no", "not", "never", "none", "nor", "neither", "without",
    "cannot", "cant", "couldnt", "didnt", "doesnt", "dont",
    "isnt", "wasnt", "werent", "wont", "unable", "failed",
    "0", "zero",
})

#: Tokens that mark the whole outcome as a failure regardless of position.
_FAILURE_TOKENS = frozenset({
    "fail", "failed", "failing", "fails", "failure", "failures",
    "error", "errored", "errors", "abort", "aborted", "aborting",
    "crash", "crashed", "timeout", "timedout", "denied", "rejected",
    "cancelled", "canceled", "incomplete", "unsuccessful",
    "unresolved", "unsolved", "blocked", "broken",
})


def _normalize_outcome(outcome: str) -> str:
    """Lowercase; apostrophes are dropped so "didn't" → "didnt"."""
    return str(outcome).lower().replace("'", "").replace("’", "")


def _outcome_clauses(outcome: str) -> list[str]:
    """Split a normalized outcome into clauses; a negation binds to one clause."""
    return [c for c in _CLAUSE_SPLIT_RE.split(_normalize_outcome(outcome)) if c.strip()]


def _clause_vetoes(clause: str) -> bool:
    """True when this clause names a failure that is not itself negated/zeroed.

    Checked over both the plain tokens and the hyphen-joined ones, so neither
    "unsuccessful" nor "un-successful" can slip through.
    """
    for stream in (_TOKEN_RE.findall(clause),
                   _TOKEN_RE.findall(_INWORD_JOIN_RE.sub("", clause))):
        negated = False
        for tok in stream:
            if tok in _FAILURE_TOKENS and not negated:
                return True
            if tok in _NEGATION_TOKENS:
                negated = True      # "no errors" / "0 failures" don't veto
    return False


def _clause_succeeds(clause: str) -> bool:
    """True when this clause asserts a good finish with no preceding negation."""
    negated = False
    for tok in _TOKEN_RE.findall(clause):
        if tok in _NEGATION_TOKENS:
            negated = True
        elif tok in _SUCCESS_TOKENS and not negated:
            return True
    return False


def outcome_is_success(outcome: str) -> bool:
    """True when a turn outcome genuinely reports a good finish.

    Word-boundary matching plus clause-scoped negation handling, so
    "incomplete", "unsuccessful", "did not pass" and "not a single test passed"
    are all failures — the bare substring test they used to be passed is what
    made them read as wins. Any un-negated failure token anywhere vetoes the
    whole outcome; ties go to *not* celebrating, since an unearned celebration
    is the dishonest direction.
    """
    clauses = _outcome_clauses(outcome)
    if any(_clause_vetoes(c) for c in clauses):
        return False
    return any(_clause_succeeds(c) for c in clauses)


# ── Pet state dataclass ───────────────────────────────────────────────────────

@dataclass
class PetState:
    status:        str            = "idle"         # "active" | "idle" | "mid_task" | "observed"
    last_task:     str            = ""
    last_cf_delta: Optional[float] = None
    memory_size:   int            = 0
    history_count: int            = 0
    updated_at:    float          = 0.0            # unix timestamp
    resumable:     bool           = False
    # Provenance. "observed" means a ⌘D capture of a frontmost app; anything
    # else is treated as agent-written. Absent on records predating the fix.
    source:        str            = ""

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

    @property
    def is_observation(self) -> bool:
        """True when this record is a ⌘D capture, not agent telemetry."""
        return (str(self.source).lower() in OBSERVED_MARKERS
                or str(self.status).lower() in OBSERVED_MARKERS)

    def mark_agent_telemetry(self) -> None:
        """Stamp this record as written by the agent itself.

        An observation is a snapshot, not a permanent brand: once real
        telemetry lands on the record it supersedes the ⌘D provenance, so the
        pet can read as focused/grinding again. Both markers have to go —
        `is_observation` also trips on a leftover ``status == "observed"``.
        """
        self.source = SOURCE_AGENT
        if str(self.status).lower() in OBSERVED_MARKERS:
            self.status = "idle"

    @property
    def seen_at(self) -> Optional[float]:
        """Timestamp of the last write, or None when the record has none.

        `updated_at` is 0.0 on a never-written pet and missing on hand-edited
        or truncated state.json files. That is *unknown* age — callers must not
        substitute "now" for it (see the honesty rule).
        """
        try:
            ts = float(self.updated_at)
        except (TypeError, ValueError):
            return None
        return ts if ts > 0.0 else None


def derive_mood(state: PetState, recent: list[dict],
                now: Optional[float] = None) -> str:
    """Map persisted state + recent history to a coarse mood label.

    Deterministic and side-effect free, so the hub, the CLI and the tests all
    agree on it. `recent` is expected newest-last, as `recent_history` returns.

    See the honesty rule above: no combination of inputs may return a mood in
    MOOD_CLAIMS_WORK for an observation-sourced, stale, or undated record.
    """
    now = time.time() if now is None else now
    # A never-touched pet has updated_at == 0.0, and a hand-written state.json
    # may omit it entirely. That is unknown age, not "seen just now": such a
    # record has not slept since the epoch (so it is not stale), but neither
    # has it proved it is current (so it may not claim work). A timestamp from
    # the *future* is the same kind of non-proof — and a worse one, since
    # `max(0.0, …)` would otherwise pin idle_for at 0 and let the record claim
    # work forever — so beyond a small clock-skew grace it is also undated.
    seen_at  = state.seen_at
    dated    = seen_at is not None and seen_at <= now + CLOCK_SKEW_GRACE
    idle_for = max(0.0, now - seen_at) if dated else None
    stale    = dated and idle_for > MOOD_SLEEP_AFTER
    current  = dated and idle_for <= LIVE_WINDOW

    # A fresh, good finish outranks liveness: the pet just did well, so it
    # celebrates even as its status settles back to idle.
    for rec in reversed(recent):
        if rec.get("event") == "turn_end":
            outcome = str(rec.get("outcome", ""))
            try:
                ts = float(rec.get("ts", 0.0) or 0.0)
            except (TypeError, ValueError):
                ts = 0.0
            # Bounded on both sides: a future-dated turn_end is not evidence of
            # a *recent* win, it is evidence of a bad clock or a hand-edit.
            age = now - ts
            if (-CLOCK_SKEW_GRACE <= age <= CELEBRATE_WINDOW
                    and outcome_is_success(outcome)):
                return "celebrating"
            break  # only the most recent turn_end is relevant

    # An observation can say "I saw this app", never "this agent is working".
    if state.is_observation:
        return "sleeping" if stale else "watching"

    if current:
        if state.status == "active":
            return "focused"
        if state.status == "mid_task":
            return "grinding"

    return "sleeping" if stale else "resting"


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

    def mood(self, agent_id: str, now: Optional[float] = None) -> str:
        """Coarse mood label for this agent's pet — see ``derive_mood``."""
        return derive_mood(self.read_state(agent_id),
                           self.recent_history(agent_id, n=6), now)

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
    # This is real agent telemetry: it supersedes whatever ⌘D last observed
    # about this pet, otherwise a single capture would pin it to "watching".
    state.mark_agent_telemetry()
    state.status    = "active"
    state.last_task = task_summary
    state.resumable = True
    pm.write_state(agent_id, state)
    pm.append_history(agent_id, {"event": "turn_start", "task": task_summary})


def on_agent_turn_end(agent_id: str, outcome: str,
                       cf: Optional[float] = None, entropy: Optional[float] = None) -> None:
    pm = get_manager()
    state = pm.read_state(agent_id)
    state.mark_agent_telemetry()      # supersedes any prior ⌘D observation
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

    md = sub.add_parser("mood", help="Print the pet's coarse mood label")
    md.add_argument("agent_id", choices=ALL_AGENTS)

    mo = sub.add_parser(
        "motion",
        help="Codex-aligned motion label from signals (or derived from pet state)",
    )
    mo.add_argument("agent_id", choices=ALL_AGENTS)
    mo.add_argument("--presence", default=None, help="live|offline|observed")
    mo.add_argument("--status", default=None, help="active|mid_task|idle|blocked|…")
    mo.add_argument("--pending-ask", action="store_true")
    mo.add_argument("--outcome", default=None, help="success|failed|review|…")
    mo.add_argument("--approved", action="store_true")
    mo.add_argument("--collapse", action="store_true")
    mo.add_argument("--json", action="store_true")

    pk = sub.add_parser(
        "package",
        help="Resolve a Codex v2 pet package (spritesheet) or procedural fallback",
    )
    pk.add_argument("pet_id", nargs="?", default="shannon")
    pk.add_argument("--json", action="store_true")
    pk.add_argument("--list", action="store_true", help="List discoverable packages")

    fr = sub.add_parser(
        "frame",
        help="Select atlas cell for a Codex motion at time t (pure math)",
    )
    fr.add_argument("motion", help="idle|running|waiting|failed|review|…")
    fr.add_argument("--t", type=float, default=0.0, help="seconds into the animation")
    fr.add_argument("--fps", type=float, default=8.0)
    fr.add_argument("--json", action="store_true")

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
            print(f"  {aid:16}  {s.status:10}  {pm.mood(aid):12}  "
                  f"resumable={s.resumable}  "
                  f"mem={s.memory_size}B  hist={s.history_count}")

    elif args.cmd == "mood":
        print(pm.mood(args.agent_id))

    elif args.cmd == "motion":
        from pet_codex_motion import PetMotionSignals, map_pet_motion

        state = pm.read_state(args.agent_id)
        presence = args.presence or (
            "live" if state.status in ("active", "mid_task") and not (
                getattr(state, "source", "") in OBSERVED_MARKERS
                or state.status in OBSERVED_MARKERS
            ) else "observed"
        )
        status = args.status or state.status
        sig = PetMotionSignals(
            presence=presence,
            status=status,
            has_pending_ask=bool(args.pending_ask),
            last_outcome=args.outcome,
            just_approved=bool(args.approved),
            entropy_collapse=bool(args.collapse),
        )
        motion = map_pet_motion(sig)
        if args.json:
            print(json.dumps({
                "agent_id": args.agent_id,
                "motion": motion,
                "presence": presence,
                "status": status,
                "mood": pm.mood(args.agent_id),
            }))
        else:
            print(motion)

    elif args.cmd == "package":
        from pet_package import list_pet_packages, resolve_pet_package

        if args.list:
            found = list_pet_packages()
            if args.json:
                print(json.dumps([p.to_dict() for p in found], indent=2))
            else:
                for p in found:
                    print(f"  {p.pet_id:20} v{p.sprite_version}  {p.spritesheet_path}")
                if not found:
                    print("(no packages found)")
        else:
            result = resolve_pet_package(args.pet_id)
            if args.json:
                print(json.dumps(result.to_dict(), indent=2))
            else:
                if result.use_procedural:
                    print(f"procedural  pet_id={result.pet_id}  ({'; '.join(result.notes)})")
                else:
                    print(
                        f"package  id={result.pet_id}  v{result.sprite_version}  "
                        f"sheet={result.spritesheet_path}"
                    )

    elif args.cmd == "frame":
        from pet_atlas import select_frame

        fr_sel = select_frame(args.motion, args.t, fps=args.fps)
        if args.json:
            print(json.dumps({
                "motion": fr_sel.motion,
                "row": fr_sel.row,
                "col": fr_sel.col,
                "frame_index": fr_sel.frame_index,
                "frames_in_row": fr_sel.frames_in_row,
                "rect": list(fr_sel.rect),
            }))
        else:
            print(
                f"{fr_sel.motion}  row={fr_sel.row} col={fr_sel.col}  "
                f"rect={fr_sel.rect}  frames={fr_sel.frames_in_row}"
            )

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
