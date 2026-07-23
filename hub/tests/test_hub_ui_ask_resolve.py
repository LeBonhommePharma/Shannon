"""Hub UI ask path: gate interaction_id must ride Approve/Deny, never a random UUID.

Tests the shipped helpers that AgentHubApp.swift HubAskPipeline mirrors:
- interaction_id_from_activity_output (event_output → gate id)
- hub_ui_resolve_payload (resolve envelope with that id)
- AuditDB upsert + resolve using the same id (end-to-end DB contract)
"""

from __future__ import annotations

import json
import sys
import time
import uuid
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import shannon_gate as sg
from agent_identity import (
    CORE_AGENT_IDS,
    hub_ui_resolve_payload,
    interaction_id_from_activity_output,
    ask_from_payload,
)


class TestGateIdFromActivityOutput:
    def test_bare_event_output_is_gate_id(self):
        # Gate logs approval_needed with event_output=ask.interaction_id
        gate_id = "ask-science-e2e-42"
        assert interaction_id_from_activity_output(gate_id, "science") == gate_id

    def test_json_event_output_extracts_interaction_id(self):
        raw = json.dumps(
            {"approval_needed": True, "interaction_id": "ask-codex-9", "prompt": "Ship?"}
        )
        assert interaction_id_from_activity_output(raw, "codex") == "ask-codex-9"

    def test_empty_falls_back_to_stable_prefix(self):
        iid = interaction_id_from_activity_output("", "grok_build", fallback_ts=1000.0)
        assert iid.startswith("ask-grok_build-")
        assert "1000" in iid

    def test_never_returns_random_uuid_shape_for_bare_id(self):
        gate_id = "inject-ask-science-1784779427"
        got = interaction_id_from_activity_output(gate_id, "science")
        # Must be exact gate id — not a new uuid4
        assert got == gate_id
        assert got != str(uuid.uuid4())


class TestHubUIResolvePayload:
    def test_payload_uses_gate_id_not_uuid(self):
        gate_id = "ask-science-e2e-99"
        payload = hub_ui_resolve_payload(gate_id, "science", True, reply="yes")
        assert payload["interaction_id"] == gate_id
        assert payload["interaction_id"] != str(uuid.uuid4())
        assert payload["approved"] is True
        assert payload["kind"] == "approval_response"
        assert payload["target_agent"] == "science"
        assert payload["source"] == "hub_ui"
        assert payload["user_reply"] == "yes"

    def test_deny_payload(self):
        payload = hub_ui_resolve_payload("ask-dispatch-1", "dispatch", False)
        assert payload["interaction_id"] == "ask-dispatch-1"
        assert payload["approved"] is False
        assert "user_reply" not in payload

    @pytest.mark.parametrize("agent_id", list(CORE_AGENT_IDS))
    def test_resolve_payload_for_each_core_agent(self, agent_id: str):
        gate_id = f"ask-{agent_id}-ui-test"
        payload = hub_ui_resolve_payload(gate_id, agent_id, True)
        assert payload["interaction_id"] == gate_id
        assert payload["target_agent"] == agent_id


class TestHubUIResolveMatchesGateDB:
    """Full path: activity output → gate id → hub resolve payload → AuditDB resolve."""

    @pytest.fixture()
    def audit_db(self, tmp_path: Path) -> sg.AuditDB:
        return sg.AuditDB(tmp_path / "agent_hub.db")

    def test_ui_resolve_matches_pending_row(self, audit_db: sg.AuditDB):
        aid = "science"
        # Simulate gate: create pending interaction
        ask = ask_from_payload(
            aid,
            {"approval_needed": True, "prompt": "Apply Softβ canary?"},
            interaction_id="ask-science-ui-path-1",
        )
        assert ask is not None
        audit_db.upsert_interaction(ask.interaction_id, ask.agent_id, ask.prompt, "pending")
        # Gate activity row: event_output = interaction_id (shipped gate behavior)
        audit_db.log_activity_event(
            aid, "approval_needed", ask.prompt, event_output=ask.interaction_id
        )

        # Hub UI extracts id the same way AgentHubApp does
        event_output = ask.interaction_id
        gate_id = interaction_id_from_activity_output(event_output, aid)
        assert gate_id == "ask-science-ui-path-1"

        # Approve uses that id (NOT a random UUID)
        random_uuid = str(uuid.uuid4())
        payload = hub_ui_resolve_payload(gate_id, aid, True)
        assert payload["interaction_id"] == gate_id
        assert payload["interaction_id"] != random_uuid

        # Gate DB resolve with the hub payload id
        rec = audit_db.resolve_interaction(payload["interaction_id"], True)
        assert rec is not None
        assert rec["status"] == "approved"
        assert rec["agent_id"] == aid
        assert rec["interaction_id"] == gate_id

        # Using a random UUID would NOT resolve the row
        miss = audit_db.resolve_interaction(random_uuid, True)
        # resolve still returns something only if row exists — random id → None
        assert miss is None or miss["interaction_id"] != gate_id

        still = audit_db.list_pending_interactions()
        assert not any(p["interaction_id"] == gate_id for p in still)

    def test_random_uuid_resolve_does_not_clear_pending(self, audit_db: sg.AuditDB):
        """Regression: UI used to send UUID.uuidString → silent drop."""
        gate_id = "ask-codex-must-survive-uuid"
        audit_db.upsert_interaction(gate_id, "codex", "Ship patch?", "pending")
        bad_uuid = str(uuid.uuid4())
        # Wrong id (old bug) does not match
        audit_db.resolve_interaction(bad_uuid, True)
        pending = audit_db.list_pending_interactions()
        assert any(p["interaction_id"] == gate_id for p in pending)
        # Correct hub path clears it
        payload = hub_ui_resolve_payload(gate_id, "codex", False)
        rec = audit_db.resolve_interaction(payload["interaction_id"], False)
        assert rec["status"] == "denied"
        pending2 = audit_db.list_pending_interactions()
        assert not any(p["interaction_id"] == gate_id for p in pending2)
