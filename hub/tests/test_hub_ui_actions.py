"""End-to-end checks for the hub UI's interactive actions.

The hub popup's buttons must do real work — LP's constraint is that nothing in
the UI may be a decoration. These tests drive a live gate over a Unix socket and
assert that the exact JSON envelopes `GateSocketClient` emits in
`hub/AgentHubApp.swift` actually reach another connected agent.

The envelopes under test:
  * sendPing            → payload.kind == "ping"
  * sendAgentMessage    → payload.kind == "user_message"
  * sendApproval        → message_type "approval_response" (already covered for
                          the pure helpers in test_hub_ui_ask_resolve.py; here we
                          confirm the gate actually resolves the interaction)
"""

from __future__ import annotations

import asyncio
import json
import uuid
from pathlib import Path

import pytest

import shannon_gate as sg


def _socket_path() -> str:
    # AF_UNIX paths cap near 104 bytes on macOS, so keep this short.
    return f"/tmp/shannon_ui_{uuid.uuid4().hex[:8]}.sock"


async def _register(path: str, agent_id: str):
    reader, writer = await asyncio.open_unix_connection(path)
    writer.write((json.dumps({"agent_id": agent_id, "task_id": "t1"}) + "\n").encode())
    await writer.drain()
    welcome = json.loads((await reader.readline()).decode())
    assert welcome["type"] == "welcome"
    return reader, writer


def _run(tmp_path, scenario, timeout: float = 10.0):
    """Run one socket scenario against a live gate.

    Deliberately avoids `async with server` / `wait_closed()`: the gate's
    per-connection handler sits in a 90 s read loop, so waiting for handlers to
    drain would block the test run rather than finish it. Closing the listener
    and letting asyncio.run cancel the outstanding handler tasks is enough.
    """
    path = _socket_path()

    async def main():
        hub = sg.AgentHub()
        hub.db = sg.AuditDB(tmp_path / "agent_hub.db")
        hub.gate = sg.ShannonGate(hub.db)
        # AgentHub.run() normally creates these inside the running loop; the
        # handler dereferences both, so a harness that bypasses run() must too.
        hub._lock = asyncio.Lock()
        hub._shutdown = asyncio.Event()
        server = await asyncio.start_unix_server(hub._handle_socket_conn, path=path)
        try:
            await asyncio.wait_for(scenario(hub, path), timeout=timeout)
        finally:
            server.close()

    try:
        asyncio.run(main())
    finally:
        Path(path).unlink(missing_ok=True)


class TestHubPingReachesAgent:
    """The bell button on an idle agent card."""

    def test_ping_envelope_is_delivered_to_target_agent(self, tmp_path):
        async def scenario(hub, path):
            # The hub UI registers as local_test (a VALID_AGENTS entry).
            _, hub_writer = await _register(path, "local_test")
            science_reader, science_writer = await _register(path, "science")

            # Exactly what GateSocketClient.sendPing puts on the wire.
            hub_writer.write((json.dumps({
                "agent_id": "local_test",
                "task_id": "hub_ui",
                "message_type": "system_event",
                "confidence": 1.0,
                "shannon_H": 0.0,
                "payload": {
                    "kind": "ping",
                    "target_agent": "science",
                    "source": "hub_ui",
                    "text": "hub ping",
                },
            }) + "\n").encode())
            await hub_writer.drain()

            envelope = json.loads(
                await asyncio.wait_for(science_reader.readline(), timeout=5.0)
            )
            assert envelope["type"] == "agent_message"
            assert envelope["from"] == "local_test"
            assert envelope["payload"]["kind"] == "ping"
            assert envelope["payload"]["target_agent"] == "science"

            hub_writer.close()
            science_writer.close()

        _run(tmp_path, scenario)


class TestHubMessageReachesAgent:
    """The inline composer on an agent card."""

    def test_user_message_envelope_is_delivered(self, tmp_path):
        async def scenario(hub, path):
            _, hub_writer = await _register(path, "local_test")
            codex_reader, codex_writer = await _register(path, "codex")

            hub_writer.write((json.dumps({
                "agent_id": "local_test",
                "task_id": "hub_ui",
                "message_type": "system_event",
                "confidence": 1.0,
                "shannon_H": 0.0,
                "payload": {
                    "kind": "user_message",
                    "target_agent": "codex",
                    "source": "hub_ui",
                    "text": "rerun the failing target",
                },
            }) + "\n").encode())
            await hub_writer.drain()

            envelope = json.loads(
                await asyncio.wait_for(codex_reader.readline(), timeout=5.0)
            )
            assert envelope["payload"]["kind"] == "user_message"
            assert envelope["payload"]["target_agent"] == "codex"
            assert envelope["payload"]["text"] == "rerun the failing target"

            hub_writer.close()
            codex_writer.close()

        _run(tmp_path, scenario)

    def test_hub_actions_are_not_mistaken_for_approvals(self, tmp_path):
        """A ping must not trip the gate's approval-resolution branch.

        That branch fires on system_event when the payload carries "approved" or
        kind == "approval_response". Ping and user_message carry neither, so they
        must be gated and broadcast like any ordinary message — never silently
        resolve someone's pending ask.
        """
        async def scenario(hub, path):
            _, hub_writer = await _register(path, "local_test")
            science_reader, science_writer = await _register(path, "science")

            iid = "ask-science-should-survive"
            hub.db.upsert_interaction(iid, "science", "Delete the build directory?")

            hub_writer.write((json.dumps({
                "agent_id": "local_test",
                "task_id": "hub_ui",
                "message_type": "system_event",
                "confidence": 1.0,
                "shannon_H": 0.0,
                "payload": {"kind": "ping", "target_agent": "science",
                            "source": "hub_ui", "text": "hub ping"},
            }) + "\n").encode())
            await hub_writer.drain()
            await asyncio.wait_for(science_reader.readline(), timeout=5.0)

            pending = {r["interaction_id"] for r in hub.db.list_pending_interactions()}
            assert iid in pending, "ping must not resolve a pending approval"

            hub_writer.close()
            science_writer.close()

        _run(tmp_path, scenario)


class TestApproveDenyResolvesInteraction:
    """Approve / Deny on an ask card — the highest-stakes control in the hub."""

    @pytest.mark.parametrize("approved", [True, False])
    def test_approval_response_resolves_the_pending_ask(self, tmp_path, approved):
        async def scenario(hub, path):
            reader, writer = await _register(path, "local_test")

            iid = "ask-science-1234"
            hub.db.upsert_interaction(iid, "science", "Overwrite results.csv?")
            assert iid in {
                r["interaction_id"] for r in hub.db.list_pending_interactions()
            }

            # Exactly what GateSocketClient.sendApproval emits.
            writer.write((json.dumps({
                "agent_id": "local_test",
                "task_id": "hub_ui",
                "message_type": "approval_response",
                "confidence": 1.0,
                "shannon_H": 0.0,
                "payload": {
                    "target_agent": "science",
                    "approved": approved,
                    "interaction_id": iid,
                    "source": "hub_ui",
                    "kind": "approval_response",
                },
            }) + "\n").encode())
            await writer.drain()

            ack = json.loads(await asyncio.wait_for(reader.readline(), timeout=5.0))
            assert ack["type"] == "approval_ack"
            assert ack["interaction_id"] == iid
            assert ack["approved"] is approved

            still_pending = {
                r["interaction_id"] for r in hub.db.list_pending_interactions()
            }
            assert iid not in still_pending, "resolved ask must leave the pending set"

            writer.close()

        _run(tmp_path, scenario)
