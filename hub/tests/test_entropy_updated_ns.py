"""entropy_updated_ns: heartbeats must not keep frozen H looking live."""

from __future__ import annotations

import sqlite3
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from shannon_gate import AuditDB
from gate_scores import should_refresh_registry_entropy


@pytest.fixture
def db_path(tmp_path: Path) -> Path:
    return tmp_path / "agent_hub.db"


@pytest.fixture
def audit(db_path: Path) -> AuditDB:
    return AuditDB(db_path)


class TestEntropyUpdatedNs:
    def test_heartbeat_preserves_score_and_entropy_clock(self, audit: AuditDB, db_path: Path):
        now = time.time_ns()
        audit.observe_agent(
            "grok_build", now, 5.55, "t1", update_entropy=True
        )
        later = now + 10_000_000_000
        # Simulate attach spam that would have written 2.38
        assert not should_refresh_registry_entropy(
            "status",
            {"event": "ingest", "source": "cmd_d", "text": "Working in Ghostty"},
        )
        audit.observe_agent(
            "grok_build",
            later,
            2.38,
            "t1",
            update_entropy=False,
            task_summary="Working in Ghostty",
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score, last_seen_ns, entropy_updated_ns "
                "FROM agents WHERE agent_id=?",
                ("grok_build",),
            ).fetchone()
        assert row is not None
        assert row[0] == pytest.approx(5.55)
        assert row[1] == later
        assert row[2] == now

    def test_upgraded_row_with_zero_entropy_updated_ns_stays_zero_on_heartbeat(
        self, audit: AuditDB, db_path: Path
    ):
        """Pre-fix production row: score=2.38, entropy_updated_ns DEFAULT 0."""
        with sqlite3.connect(db_path) as conn:
            # Force schema
            _ = audit  # open DB
        now = time.time_ns()
        with sqlite3.connect(db_path) as conn:
            conn.execute(
                """
                INSERT INTO agents
                    (agent_id, status, connected_at, last_seen_ns, disconnected_at,
                     message_count, entropy_score, entropy_updated_ns, task_id)
                VALUES ('stuck', 'idle', ?, ?, ?, 6, 2.38, 0, 'ingest')
                """,
                (now - 10**12, now - 10**12, now - 10**12),
            )
            conn.commit()
        # Heartbeat advances last_seen only
        later = now
        audit.observe_agent(
            "stuck", later, 2.38, "ingest", update_entropy=False
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score, last_seen_ns, entropy_updated_ns "
                "FROM agents WHERE agent_id='stuck'"
            ).fetchone()
        assert row[0] == pytest.approx(2.38)
        assert row[1] == later
        assert row[2] == 0 or row[2] is None
        # Pill path contract: GateEntropyClock equivalent — no usable clock
        assert (row[2] or 0) == 0
