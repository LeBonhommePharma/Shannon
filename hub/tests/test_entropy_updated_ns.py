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

    def test_upgraded_row_with_zero_entropy_updated_ns_is_cleared_on_heartbeat(
        self, audit: AuditDB, db_path: Path
    ):
        """Pre-fix production row: score=2.38, entropy_updated_ns DEFAULT 0.

        Heartbeats must not keep advertising unstamped H. Clear the poison
        score while leaving the measurement clock at 0 (still not current).
        """
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
        later = now
        audit.observe_agent(
            "stuck", later, 2.38, "ingest", update_entropy=False
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score, last_seen_ns, entropy_updated_ns "
                "FROM agents WHERE agent_id='stuck'"
            ).fetchone()
        assert row[0] == pytest.approx(0.0), "unstamped freeze must be zeroed"
        assert row[1] == later
        assert (row[2] or 0) == 0, "still no honest measurement clock"

    def test_stamped_score_survives_heartbeat(self, audit: AuditDB, db_path: Path):
        """A real substantive write keeps H across attach spam."""
        now = time.time_ns()
        audit.observe_agent("science", now, 4.12, "t1", update_entropy=True)
        later = now + 5_000_000_000
        audit.observe_agent(
            "science",
            later,
            2.38,
            "t1",
            update_entropy=False,
            task_summary="Working in Ghostty",
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score, last_seen_ns, entropy_updated_ns "
                "FROM agents WHERE agent_id='science'"
            ).fetchone()
        assert row[0] == pytest.approx(4.12)
        assert row[1] == later
        assert row[2] == now

    def test_update_agent_seen_clears_unstamped_poison(
        self, audit: AuditDB, db_path: Path
    ):
        now = time.time_ns()
        with sqlite3.connect(db_path) as conn:
            _ = audit
            conn.execute(
                """
                INSERT INTO agents
                    (agent_id, status, connected_at, last_seen_ns, disconnected_at,
                     message_count, entropy_score, entropy_updated_ns, task_id)
                VALUES ('poison', 'active', ?, ?, NULL, 3, 2.3763, 0, 't')
                """,
                (now, now),
            )
            conn.commit()
        later = now + 1_000_000_000
        audit.update_agent_seen(
            "poison", later, 2.38, "t", update_entropy=False
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score, entropy_updated_ns FROM agents "
                "WHERE agent_id='poison'"
            ).fetchone()
        assert row[0] == pytest.approx(0.0)
        assert (row[1] or 0) == 0

    def test_open_db_scrubs_unstamped_attach_spam_signature(
        self, tmp_path: Path
    ):
        """Opening AuditDB clears leftover ~2.38 with entropy_updated_ns=0."""
        db_path = tmp_path / "scrub.db"
        # First open creates schema
        _ = AuditDB(db_path)
        now = time.time_ns()
        with sqlite3.connect(db_path) as conn:
            conn.execute(
                """
                INSERT INTO agents
                    (agent_id, status, connected_at, last_seen_ns, disconnected_at,
                     message_count, entropy_score, entropy_updated_ns, task_id)
                VALUES ('grok_build', 'observed', ?, ?, ?, 9, 2.3763, 0, 'ingest')
                """,
                (now, now, now),
            )
            conn.commit()
        # Re-open must scrub on __init__ (simulates gate restart).
        _ = AuditDB(db_path)
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score, entropy_updated_ns FROM agents "
                "WHERE agent_id='grok_build'"
            ).fetchone()
        assert row[0] == pytest.approx(0.0), "attach-spam signature must be zeroed"
        assert (row[1] or 0) == 0
