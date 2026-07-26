"""ENH-017: optional structured tool_kind on agent_activity rows."""

from __future__ import annotations

import sqlite3
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shannon_gate as sg


@pytest.fixture()
def audit_db(tmp_path: Path) -> sg.AuditDB:
    return sg.AuditDB(tmp_path / "agent_hub.db")


class TestNormalizeToolKind:
    def test_known_kinds_pass_through(self):
        for k in ("read", "edit", "shell", "test", "browse", "other"):
            assert sg.normalize_tool_kind(k) == k
            assert sg.normalize_tool_kind(k.upper()) == k

    def test_bash_alias_maps_to_shell(self):
        assert sg.normalize_tool_kind("bash") == "shell"
        assert sg.normalize_tool_kind("terminal") == "shell"

    def test_unknown_is_none(self):
        assert sg.normalize_tool_kind(None) is None
        assert sg.normalize_tool_kind("") is None
        assert sg.normalize_tool_kind("StrReplace") is None
        assert sg.normalize_tool_kind("tool_call") is None


class TestResolveActivityToolKind:
    def test_payload_tool_kind_wins(self):
        assert (
            sg.resolve_activity_tool_kind(
                {"tool_kind": "edit", "tool": "shell"}, event_type="bash"
            )
            == "edit"
        )

    def test_event_type_when_payload_empty(self):
        assert sg.resolve_activity_tool_kind({}, event_type="bash") == "shell"
        assert sg.resolve_activity_tool_kind({}, event_type="edit") == "edit"

    def test_does_not_invent_from_free_text(self):
        assert (
            sg.resolve_activity_tool_kind(
                {"label": "Edited store.ts"}, event_type="tool_call"
            )
            is None
        )


class TestActivityToolKindColumn:
    def test_new_db_has_tool_kind_column(self, audit_db: sg.AuditDB):
        with audit_db._connect() as conn:
            cols = {
                row[1] for row in conn.execute("PRAGMA table_info(agent_activity)")
            }
        assert "tool_kind" in cols

    def test_migration_adds_tool_kind_to_legacy_table(self, tmp_path: Path):
        path = tmp_path / "legacy.db"
        # Pre-create only agent_activity without tool_kind; AuditDB will
        # CREATE IF NOT EXISTS other tables and migrate this one additively.
        with sqlite3.connect(str(path)) as conn:
            conn.executescript(
                """
                CREATE TABLE agent_activity (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    agent_id TEXT NOT NULL,
                    event_at_ns INTEGER NOT NULL,
                    event_type TEXT NOT NULL,
                    event_label TEXT NOT NULL,
                    event_output TEXT
                );
                """
            )
            cols_before = {
                row[1] for row in conn.execute("PRAGMA table_info(agent_activity)")
            }
        assert "tool_kind" not in cols_before

        db = sg.AuditDB(path)
        with db._connect() as conn:
            cols = {
                row[1] for row in conn.execute("PRAGMA table_info(agent_activity)")
            }
        assert "tool_kind" in cols

    def test_log_activity_stores_normalized_tool_kind(self, audit_db: sg.AuditDB):
        audit_db.log_activity_event(
            "codex", "tool_call", "patch store.ts", "ok", tool_kind="edit"
        )
        audit_db.log_activity_event(
            "codex", "bash", "ls", "done", tool_kind="bash"
        )
        audit_db.log_activity_event(
            "codex", "status", "working", None, tool_kind="StrReplace"
        )
        with audit_db._connect() as conn:
            rows = conn.execute(
                "SELECT event_label, tool_kind FROM agent_activity ORDER BY id"
            ).fetchall()
        assert rows[0]["tool_kind"] == "edit"
        assert rows[1]["tool_kind"] == "shell"  # bash normalized
        assert rows[2]["tool_kind"] is None  # unknown not invented

    def test_log_activity_without_tool_kind_is_null(self, audit_db: sg.AuditDB):
        audit_db.log_activity_event("science", "tool_call", "Dock(1SG0)", "ok")
        with audit_db._connect() as conn:
            kind = conn.execute(
                "SELECT tool_kind FROM agent_activity WHERE event_label=?",
                ("Dock(1SG0)",),
            ).fetchone()["tool_kind"]
        assert kind is None
