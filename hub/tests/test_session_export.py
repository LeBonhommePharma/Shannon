"""Tests for hub/session_export.py — audit DB timeline export."""

from __future__ import annotations

import json
import time
from pathlib import Path

import pytest

import shannon_gate as sg
from session_export import (
    export_session_events,
    export_session_jsonl,
    write_jsonl,
)


@pytest.fixture
def audit_db(tmp_path: Path) -> sg.AuditDB:
    return sg.AuditDB(tmp_path / "agent_hub.db")


class TestExportSessionEvents:
    def test_empty_db_returns_empty_list(self, audit_db: sg.AuditDB):
        events = export_session_events(audit_db.db_path)
        assert events == []

    def test_activity_events_exported(self, audit_db: sg.AuditDB):
        audit_db.log_activity_event(
            "science", "tool_call", "Dock(1SG0)", "CF=-187.3"
        )
        audit_db.log_activity_event(
            "codex", "edit", "patch.py", "3 lines"
        )

        events = export_session_events(audit_db.db_path)
        assert len(events) >= 2
        kinds = {e["kind"] for e in events}
        assert "tool_call" in kinds
        assert "edit" in kinds
        for e in events:
            assert set(e.keys()) == {"ts_ns", "agent_id", "kind", "label", "detail"}
            assert isinstance(e["ts_ns"], int)
            assert e["ts_ns"] > 0

    def test_interactions_exported(self, audit_db: sg.AuditDB):
        audit_db.upsert_interaction(
            "ix-1", "grok_build", "Approve force-push to main?", status="pending"
        )
        events = export_session_events(audit_db.db_path)
        assert events, "expected non-empty export after interaction upsert"
        kinds = [e["kind"] for e in events]
        assert any(k.startswith("interaction_") for k in kinds)
        pending = [e for e in events if e["kind"] == "interaction_pending"]
        assert pending
        assert "force-push" in pending[0]["detail"]
        assert pending[0]["agent_id"] == "grok_build"

    def test_mixed_timeline_sorted(self, audit_db: sg.AuditDB):
        audit_db.log_activity_event("science", "dock", "1ACJ", "ok")
        time.sleep(0.002)
        audit_db.upsert_interaction("ix-2", "science", "Continue docking?", "pending")
        time.sleep(0.002)
        audit_db.log_activity_event("science", "bash", "ls", "done")

        events = export_session_events(audit_db.db_path)
        assert len(events) >= 3
        ts = [e["ts_ns"] for e in events]
        assert ts == sorted(ts)
        kinds = {e["kind"] for e in events}
        assert "dock" in kinds
        assert "bash" in kinds
        assert any(k.startswith("interaction_") for k in kinds)

    def test_since_ns_filters(self, audit_db: sg.AuditDB):
        audit_db.log_activity_event("codex", "build", "old", "v1")
        cutoff = time.time_ns()
        time.sleep(0.002)
        audit_db.log_activity_event("codex", "build", "new", "v2")

        events = export_session_events(audit_db.db_path, since_ns=cutoff)
        labels = [e["label"] for e in events]
        assert "new" in labels
        assert "old" not in labels

    def test_missing_db_returns_empty(self, tmp_path: Path):
        assert export_session_events(tmp_path / "nope.db") == []


class TestJsonlExport:
    def test_export_session_jsonl(self, audit_db: sg.AuditDB):
        audit_db.log_activity_event("dispatch", "status", "running", "")
        text = export_session_jsonl(audit_db.db_path)
        assert text.strip()
        lines = [json.loads(line) for line in text.strip().splitlines()]
        assert lines
        assert lines[0]["kind"] == "status"

    def test_write_jsonl(self, audit_db: sg.AuditDB, tmp_path: Path):
        audit_db.log_activity_event("cowork", "edit", "f.py", "ok")
        out = tmp_path / "session.jsonl"
        n = write_jsonl(out, db_path=audit_db.db_path)
        assert n >= 1
        assert out.exists()
        loaded = [json.loads(line) for line in out.read_text().splitlines() if line]
        assert loaded[0]["agent_id"] == "cowork"

    def test_write_jsonl_shipped_cli_call_shape(self, audit_db: sg.AuditDB, tmp_path: Path):
        """The `./scripts/shannon export` entry must use write_jsonl(out, db_path=db).

        Regression: write_jsonl(db, out) treated the DB path as the output file
        and the output Path as ``events``, corrupting the call.
        """
        audit_db.log_activity_event("science", "status", "cli-shape", "ok")
        db = audit_db.db_path
        out = tmp_path / "session_export.jsonl"
        # Exact call shape used by scripts/shannon export:
        n = write_jsonl(out, db_path=db)
        assert n >= 1
        assert out.is_file()
        body = out.read_text()
        assert "cli-shape" in body or "science" in body

    def test_scripts_shannon_export_uses_db_path_kwarg(self):
        """Static: the shipped CLI must not pass (db, out) positionally."""
        script = Path(__file__).resolve().parents[2] / "scripts" / "shannon"
        text = script.read_text()
        assert "write_jsonl(out, db_path=db)" in text
        assert "write_jsonl(db, out)" not in text
