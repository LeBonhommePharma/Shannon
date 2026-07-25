"""
Entropy data integrity — agents cannot forge or launder "current H".

Threats under test:
  1. Self-report (shannon_H) must never be written to agents.entropy_score.
  2. Identity spoof on a bound socket must not update the victim's row.
  3. Non-finite / negative self-reports cannot buy a free pass.
  4. Gate-computed H is what the registry stores even when the agent lies.
"""

from __future__ import annotations

import asyncio
import json
import math
import sqlite3
import uuid
from pathlib import Path

import pytest

import shannon_gate as sg


WORK_TEXT = " ".join(f"delta{i}" for i in range(8))


def _payload(text: str = WORK_TEXT) -> dict:
    return {"text": text}


@pytest.fixture
def db_path(tmp_path):
    return tmp_path / "integrity.db"


@pytest.fixture
def gate(db_path):
    return sg.ShannonGate(sg.AuditDB(db_path))


def _msg(**over):
    base = dict(
        agent_id="science",
        task_id="t1",
        message_type="status",
        payload=_payload(),
        timestamp_ns=0,
        shannon_H=3.0,
        confidence=0.95,
    )
    base.update(over)
    return sg.AgentMessage(**base)


# ── Pure helpers ──────────────────────────────────────────────────────────────

class TestRegistryEntropyScore:
    def test_uses_computed_h_never_self_report(self, gate):
        # Lie hard: claim H=1.0 on content the gate measures ~3.18
        d = gate.evaluate(_msg(shannon_H=1.0))
        score = sg.registry_entropy_score(d)
        assert score == d.computed_H
        assert score != 1.0
        assert score > 2.0  # gate measurement, not the lie

    def test_non_finite_computed_h_becomes_zero(self):
        d = sg.GateDecision(
            decision="pass", reasons=[], computed_H=float("nan"), computed_D=0.0
        )
        assert sg.registry_entropy_score(d) == 0.0


class TestSanitizeSelfReport:
    def test_nan_and_negative_become_silence(self):
        assert sg.sanitize_self_report(float("nan"), 1.0) == (0.0, 1.0)
        assert sg.sanitize_self_report(float("-inf"), 0.5) == (0.0, 0.5)
        assert sg.sanitize_self_report(-3.0, 1.0) == (0.0, 1.0)

    def test_garbage_types_become_silence(self):
        assert sg.sanitize_self_report("not-a-number", "x") == (0.0, 1.0)

    def test_confidence_clamped(self):
        h, c = sg.sanitize_self_report(2.5, 3.0)
        assert h == 2.5
        assert c == 1.0
        _, c2 = sg.sanitize_self_report(2.5, -1.0)
        assert c2 == 0.0


class TestBindSocketAgentId:
    def test_matching_claim_is_clean(self):
        assert sg.bind_socket_agent_id("science", "science") == ("science", None)

    def test_spoof_keeps_bound_identity(self):
        effective, spoof = sg.bind_socket_agent_id("victim", "attacker")
        assert effective == "attacker"
        assert spoof == "victim"

    def test_missing_claim_uses_bound(self):
        assert sg.bind_socket_agent_id(None, "science") == ("science", None)
        assert sg.bind_socket_agent_id("", "science") == ("science", None)


# ── Registry write path ───────────────────────────────────────────────────────

class TestRegistryNeverStoresSelfReport:
    def test_update_agent_seen_stores_gate_h(self, gate, db_path):
        d = gate.evaluate(_msg(agent_id="science", shannon_H=1.0))
        assert "self_report_divergence" in d.reasons
        gate.db.upsert_agent("science", "active", 1)
        gate.db.update_agent_seen(
            "science", 2, sg.registry_entropy_score(d), "t1"
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score FROM agents WHERE agent_id=?",
                ("science",),
            ).fetchone()
        assert row is not None
        assert row[0] == pytest.approx(d.computed_H)
        assert row[0] != pytest.approx(1.0)


# ── End-to-end socket identity binding ────────────────────────────────────────

def _socket_scenario(db_path: Path, register_as: str, messages: list[dict]) -> list[dict]:
    """Register as one agent, send messages (which may claim other ids), return replies."""
    socket_path = f"/tmp/shannon_id_{uuid.uuid4().hex[:8]}.sock"

    async def scenario():
        hub = sg.AgentHub(db_path=db_path)
        hub.gate = sg.ShannonGate(hub.db)
        hub._lock = asyncio.Lock()
        hub._shutdown = asyncio.Event()
        server = await asyncio.start_unix_server(
            hub._handle_socket_conn, path=socket_path
        )
        replies = []
        async with server:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            writer.write(
                (json.dumps({"agent_id": register_as, "task_id": "t1"}) + "\n").encode()
            )
            await writer.drain()
            await reader.readline()  # welcome
            for msg in messages:
                writer.write((json.dumps(msg) + "\n").encode())
                await writer.drain()
                replies.append(json.loads((await reader.readline()).decode()))
            writer.close()
        return replies, hub

    try:
        return asyncio.run(scenario())
    finally:
        Path(socket_path).unlink(missing_ok=True)


class TestIdentitySpoofCannotLaunderEntropy:
    def test_spoof_does_not_update_victim_entropy(self, db_path):
        # Pre-seed the victim with a known gate H so we can prove it is untouched.
        db = sg.AuditDB(db_path)
        db.upsert_agent("science", "active", 1)
        db.update_agent_seen("science", 10, 7.77, "seed")

        liar_msg = {
            "agent_id": "science",  # spoof claim
            "task_id": "t1",
            "message_type": "status",
            "payload": _payload(),
            "shannon_H": 1.0,
            "confidence": 1.0,
        }
        replies, hub = _socket_scenario(db_path, register_as="codex", messages=[liar_msg])
        assert replies, "expected a gate response"
        # Victim row must still show the pre-seeded score, not the attacker's measurement.
        with sqlite3.connect(db_path) as conn:
            victim = conn.execute(
                "SELECT entropy_score FROM agents WHERE agent_id=?",
                ("science",),
            ).fetchone()
            attacker = conn.execute(
                "SELECT entropy_score FROM agents WHERE agent_id=?",
                ("codex",),
            ).fetchone()
            spoof_events = conn.execute(
                "SELECT event_label FROM agent_activity WHERE event_label=?",
                ("identity_spoof",),
            ).fetchall()
        assert victim is not None
        assert victim[0] == pytest.approx(7.77)
        assert attacker is not None
        # Attacker was scored under their bound identity (gate H, not claim 1.0).
        assert attacker[0] != pytest.approx(1.0)
        assert attacker[0] > 0
        assert spoof_events, "identity_spoof must be audited"

    def test_honest_same_id_still_updates_own_row(self, db_path):
        msg = {
            "agent_id": "science",
            "task_id": "t1",
            "message_type": "status",
            "payload": _payload(),
            "shannon_H": 3.0,
            "confidence": 0.95,
        }
        replies, hub = _socket_scenario(db_path, register_as="science", messages=[msg])
        assert replies
        d = hub.gate.evaluate(
            sg.AgentMessage(
                agent_id="science", task_id="t1", message_type="status",
                payload=_payload(), timestamp_ns=0, shannon_H=3.0, confidence=0.95,
            )
        )
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score FROM agents WHERE agent_id=?",
                ("science",),
            ).fetchone()
        assert row is not None
        assert row[0] == pytest.approx(d.computed_H, abs=0.2)


class TestLieDoesNotBecomeRegistryH:
    def test_http_path_stores_gate_h(self, db_path):
        pytest.importorskip("aiohttp")
        from aiohttp.test_utils import TestClient, TestServer

        async def scenario():
            hub = sg.AgentHub(db_path=db_path)
            hub.gate = sg.ShannonGate(hub.db)
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()
            client = TestClient(TestServer(hub.build_http_app()))
            await client.start_server()
            try:
                body = {
                    "agent_id": "science",
                    "task_id": "t1",
                    "message_type": "status",
                    "payload": _payload(),
                    "shannon_H": 1.0,
                    "confidence": 1.0,
                }
                r = await client.post("/message", json=body)
                assert r.status == 200
                resp = await r.json()
                # Envelope must not leak gate_H (gradient for lying).
                assert "gate_H" not in resp
                assert "computed_H" not in resp
            finally:
                await client.close()
            return hub

        hub = asyncio.run(scenario())
        with sqlite3.connect(db_path) as conn:
            row = conn.execute(
                "SELECT entropy_score FROM agents WHERE agent_id=?",
                ("science",),
            ).fetchone()
            audit = conn.execute(
                "SELECT self_H, gate_H FROM agent_messages WHERE agent_id=? "
                "ORDER BY received_at_ns DESC LIMIT 1",
                ("science",),
            ).fetchone()
        assert row is not None
        assert audit is not None
        self_h, gate_h = audit
        assert self_h == pytest.approx(1.0)
        assert gate_h == pytest.approx(row[0])
        assert row[0] != pytest.approx(1.0)
