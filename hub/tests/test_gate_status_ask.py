"""Integration: inject status + ask for core agents through AuditDB + reducers.

Full socket round-trip is exercised by scripts/inject_agent_updates.py when the
gate is running; these tests call the same shipped DB methods and pure helpers.
"""

from __future__ import annotations

import json
import sqlite3
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shannon_gate as sg
from agent_identity import CORE_AGENT_IDS, ask_from_payload, resolve_ask, status_from_payload


@pytest.fixture()
def audit_db(tmp_path: Path) -> sg.AuditDB:
    db = sg.AuditDB(tmp_path / "agent_hub.db")
    return db


class TestGateStatusIngest:
    def test_all_six_agents_update_registry(self, audit_db: sg.AuditDB):
        now = time.time_ns()
        for aid in CORE_AGENT_IDS:
            audit_db.upsert_agent(aid, "idle", now)
            upd = status_from_payload(
                aid, "status", {"message": f"{aid} working on demo task"}
            )
            audit_db.update_agent_seen(
                aid,
                time.time_ns(),
                entropy_score=2.5,
                task_id="demo",
                task_summary=upd.task_summary,
                status=upd.status,
            )
            audit_db.log_activity_event(
                aid, upd.event_type, upd.event_label, event_output=upd.task_summary
            )

        with audit_db._connect() as conn:
            rows = conn.execute(
                "SELECT agent_id, status, task_summary FROM agents ORDER BY agent_id"
            ).fetchall()
        by_id = {r[0]: r for r in rows}
        for aid in CORE_AGENT_IDS:
            assert aid in by_id, f"{aid} missing from agents table"
            assert by_id[aid][1] == "active"
            assert by_id[aid][2], f"{aid} empty task_summary"
            assert "demo" in by_id[aid][2] or aid.split("_")[0] in by_id[aid][2]

        with audit_db._connect() as conn:
            n = conn.execute("SELECT COUNT(*) FROM agent_activity").fetchone()[0]
        assert n >= len(CORE_AGENT_IDS)


class TestGateAskResolve:
    def test_ask_persist_and_resolve(self, audit_db: sg.AuditDB):
        aid = "science"
        ask = ask_from_payload(
            aid,
            {"approval_needed": True, "prompt": "Apply Softβ canary?"},
            interaction_id="ask-science-1",
        )
        assert ask is not None
        audit_db.upsert_interaction(ask.interaction_id, ask.agent_id, ask.prompt, "pending")
        audit_db.log_activity_event(
            aid, "approval_needed", ask.prompt, event_output=ask.interaction_id
        )

        pending = audit_db.list_pending_interactions()
        assert any(p["interaction_id"] == "ask-science-1" for p in pending)
        assert pending[0]["agent_id"] == aid

        rec = audit_db.resolve_interaction("ask-science-1", True)
        assert rec is not None
        assert rec["status"] == "approved"
        assert rec["agent_id"] == aid

        still = audit_db.list_pending_interactions()
        assert not any(p["interaction_id"] == "ask-science-1" for p in still)

        # Pure reducer agrees
        assert resolve_ask(ask, True).status == "approved"
        assert resolve_ask(ask, False).status == "denied"

    @pytest.mark.parametrize("agent_id", list(CORE_AGENT_IDS))
    def test_ask_unit_for_each_agent(self, agent_id: str, audit_db: sg.AuditDB):
        iid = f"ask-{agent_id}"
        ask = ask_from_payload(
            agent_id,
            {"approval_needed": True, "prompt": f"Continue {agent_id}?"},
            interaction_id=iid,
        )
        assert ask is not None
        audit_db.upsert_interaction(iid, agent_id, ask.prompt, "pending")
        denied = audit_db.resolve_interaction(iid, False)
        assert denied["status"] == "denied"
