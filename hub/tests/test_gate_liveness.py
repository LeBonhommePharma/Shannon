"""Liveness bookkeeping in the agents table.

`last_seen_ns` says when an agent last *spoke*. On its own it cannot answer the
question every UI actually asks — "is this agent still there?" — because silence
looks the same as death. These tests pin down `heartbeat_ns`, which answers it,
and the startup reconciliation that stops a killed daemon's rows from claiming
an open connection for ever.
"""
import time

import shannon_gate as sg


def _db(tmp_path):
    return sg.AuditDB(tmp_path / "agent_hub.db")


def _row(db, agent_id):
    with db._connect() as conn:
        return dict(
            conn.execute(
                "SELECT status, last_seen_ns, heartbeat_ns, disconnected_at "
                "FROM agents WHERE agent_id = ?",
                (agent_id,),
            ).fetchone()
        )


class TestHeartbeat:
    def test_connect_seeds_heartbeat(self, tmp_path):
        db = _db(tmp_path)
        now = time.time_ns()
        db.upsert_agent("science", "active", now)
        assert _row(db, "science")["heartbeat_ns"] == now

    def test_message_advances_both_clocks(self, tmp_path):
        db = _db(tmp_path)
        db.upsert_agent("science", "active", time.time_ns())
        later = time.time_ns() + int(1e9)
        db.update_agent_seen("science", later, 0.0, "t", task_summary="docking")
        row = _row(db, "science")
        assert row["last_seen_ns"] == later
        assert row["heartbeat_ns"] == later

    def test_heartbeat_moves_without_touching_last_seen(self, tmp_path):
        """The point of the column: prove the connection is open while the
        agent stays silent, instead of letting readers age `last_seen_ns` out
        and call a working agent offline."""
        db = _db(tmp_path)
        spoke_at = time.time_ns()
        db.upsert_agent("science", "active", spoke_at)
        db.update_agent_seen("science", spoke_at, 0.0, "t")

        beat_at = spoke_at + int(600e9)
        db.heartbeat_agents(["science"], beat_at, int(300e9))
        row = _row(db, "science")
        assert row["last_seen_ns"] == spoke_at, "last activity must not be faked"
        assert row["heartbeat_ns"] == beat_at
        assert row["disconnected_at"] is None

    def test_quiet_connected_agent_is_demoted_to_idle(self, tmp_path):
        db = _db(tmp_path)
        now = time.time_ns()
        for agent in ("science", "codex"):
            db.upsert_agent(agent, "active", now)
        db.update_agent_seen("science", now, 0.0, "t", status="active")
        db.update_agent_seen("codex", now - int(600e9), 0.0, "t", status="active")

        db.heartbeat_agents(["science", "codex"], now, int(300e9))
        assert _row(db, "science")["status"] == "active"
        assert _row(db, "codex")["status"] == "idle"

    def test_blocked_status_survives_the_heartbeat(self, tmp_path):
        """`blocked` is a gate verdict, not a staleness claim — leave it."""
        db = _db(tmp_path)
        now = time.time_ns()
        db.upsert_agent("science", "active", now)
        db.update_agent_seen("science", now - int(900e9), 0.0, "t", status="blocked")
        db.heartbeat_agents(["science"], now, int(300e9))
        assert _row(db, "science")["status"] == "blocked"

    def test_empty_connection_list_is_a_no_op(self, tmp_path):
        db = _db(tmp_path)
        now = time.time_ns()
        db.upsert_agent("science", "active", now)
        db.heartbeat_agents([], now + int(60e9), int(300e9))
        assert _row(db, "science")["heartbeat_ns"] == now

    def test_disconnect_stops_the_heartbeat_at_the_hangup(self, tmp_path):
        db = _db(tmp_path)
        now = time.time_ns()
        db.upsert_agent("science", "active", now)
        gone = now + int(30e9)
        db.update_agent_disconnect("science", gone)
        row = _row(db, "science")
        assert row["status"] == "idle"
        assert row["disconnected_at"] == gone
        assert row["heartbeat_ns"] == gone


class TestStaleRowReconciliation:
    def test_startup_closes_rows_left_open_by_a_killed_daemon(self, tmp_path):
        db = _db(tmp_path)
        now = time.time_ns()
        db.upsert_agent("science", "active", now)      # never disconnected
        db.upsert_agent("codex", "active", now)
        db.update_agent_disconnect("codex", now)       # hung up cleanly

        closed = db.mark_all_disconnected(now + int(5e9))
        assert closed == 1, "only the row still claiming a connection"
        assert _row(db, "science")["disconnected_at"] == now + int(5e9)
        assert _row(db, "science")["status"] == "idle"
        assert _row(db, "codex")["disconnected_at"] == now

    def test_reconciliation_is_idempotent(self, tmp_path):
        db = _db(tmp_path)
        db.upsert_agent("science", "active", time.time_ns())
        assert db.mark_all_disconnected(time.time_ns()) == 1
        assert db.mark_all_disconnected(time.time_ns()) == 0


class TestMigration:
    def test_heartbeat_column_is_added_to_an_older_database(self, tmp_path):
        """A DB from a gate that predates the column must migrate in place —
        the pill reads this file while the daemon runs."""
        import sqlite3

        path = tmp_path / "legacy.db"
        conn = sqlite3.connect(path)
        conn.executescript(
            """
            CREATE TABLE agents (
                agent_id TEXT PRIMARY KEY, status TEXT NOT NULL DEFAULT 'idle',
                connected_at INTEGER, last_seen_ns INTEGER NOT NULL DEFAULT 0,
                disconnected_at INTEGER, task_id TEXT DEFAULT '',
                message_count INTEGER DEFAULT 0, entropy_score REAL DEFAULT 0.0,
                task_summary TEXT DEFAULT '', auth_method TEXT DEFAULT 'socket_secret');
            INSERT INTO agents (agent_id, status, last_seen_ns) VALUES ('science', 'idle', 1);
            """
        )
        conn.commit()
        conn.close()

        db = sg.AuditDB(path)
        cols = {r[1] for r in db._connect().execute("PRAGMA table_info(agents)")}
        assert "heartbeat_ns" in cols
        assert _row(db, "science")["heartbeat_ns"] is None, "no beat is not a stale beat"
