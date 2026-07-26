"""P0.2: approval_needed must surface even when gate decision is blocked.

A long careful approval prompt scores high message-content H and used to hit
the hard-block path, then return before upsert_interaction — the human never
saw the ask. This pins the fix on the shipped handle path via AuditDB.
"""

from __future__ import annotations

import asyncio
import time
from pathlib import Path

import pytest

import shannon_gate as sg


def _verbose_prompt(n_words: int = 80) -> str:
    # Enough distinct tokens to push combined message H above H_BLOCK_THRESHOLD.
    return " ".join(f"approval_token_{i}" for i in range(n_words))


@pytest.fixture
def db_path(tmp_path: Path) -> Path:
    return tmp_path / "approval.db"


@pytest.fixture
def hub(db_path: Path) -> sg.AgentHub:
    return sg.AgentHub(db_path=db_path)


class TestIsHumanApprovalRequest:
    def test_message_type(self):
        msg = sg.AgentMessage(
            agent_id="science",
            task_id="t",
            message_type="approval_needed",
            payload={"prompt": "Ship?"},
            timestamp_ns=0,
            shannon_H=0.0,
            confidence=1.0,
        )
        assert sg.is_human_approval_request(msg)

    def test_payload_flags(self):
        for key in ("approval_needed", "require_approval"):
            msg = sg.AgentMessage(
                agent_id="science",
                task_id="t",
                message_type="status",
                payload={key: True, "prompt": "Ship?"},
                timestamp_ns=0,
                shannon_H=0.0,
                confidence=1.0,
            )
            assert sg.is_human_approval_request(msg)

    def test_plain_status_is_not_ask(self):
        msg = sg.AgentMessage(
            agent_id="science",
            task_id="t",
            message_type="status",
            payload={"text": "working"},
            timestamp_ns=0,
            shannon_H=0.0,
            confidence=1.0,
        )
        assert not sg.is_human_approval_request(msg)


class TestApprovalSurfacesWhenBlocked:
    def test_evaluate_verbose_approval_still_scored(self, hub: sg.AgentHub):
        """Verbose approval is scored (text proxy may observe) but never drops the ask.

        After polarity fix, high word-H no longer hard-blocks by default; the
        important property is that evaluate returns a legal decision and the
        human-surface path still runs (covered by the socket e2e test).
        """
        d = hub.gate.evaluate(
            sg.AgentMessage(
                agent_id="science",
                task_id="t1",
                message_type="approval_needed",
                payload={"prompt": _verbose_prompt(120), "approval_needed": True},
                timestamp_ns=0,
                shannon_H=0.0,
                confidence=1.0,
            )
        )
        assert d.decision in ("flagged", "blocked", "pass")
        assert d.computed_H > 0
        assert sg.is_human_approval_request(
            sg.AgentMessage(
                agent_id="science",
                task_id="t1",
                message_type="approval_needed",
                payload={"prompt": _verbose_prompt(120), "approval_needed": True},
                timestamp_ns=0,
                shannon_H=0.0,
                confidence=1.0,
            )
        )

    def test_verbose_approval_surfaces_even_if_text_proxy_enforce_blocks(
        self, db_path: Path, monkeypatch
    ):
        """Even under legacy TEXT_PROXY=enforce hard-block, the ask is persisted."""
        monkeypatch.setattr(sg, "TEXT_PROXY_MODE", "enforce")
        monkeypatch.setattr(sg, "BEHAVIOR_MODE", "off")
        import asyncio
        import json
        import uuid
        from pathlib import Path as P

        socket_path = f"/tmp/shannon_ask_proxy_{uuid.uuid4().hex[:8]}.sock"
        prompt = _verbose_prompt(120)
        iid = "ask-proxy-enforce-surface"

        async def scenario():
            hub = sg.AgentHub(db_path=db_path)
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()
            server = await asyncio.start_unix_server(
                hub._handle_socket_conn, path=socket_path
            )
            async with server:
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write(
                    (json.dumps({"agent_id": "science", "task_id": "t1"}) + "\n").encode()
                )
                await writer.drain()
                await reader.readline()
                body = {
                    "agent_id": "science",
                    "task_id": "t1",
                    "message_type": "approval_needed",
                    "message_id": iid,
                    "payload": {
                        "prompt": prompt,
                        "approval_needed": True,
                        "interaction_id": iid,
                    },
                    "shannon_H": 0.0,
                    "confidence": 1.0,
                }
                writer.write((json.dumps(body) + "\n").encode())
                await writer.drain()
                reply = json.loads((await reader.readline()).decode())
                writer.close()
                return reply, hub

        try:
            reply, hub = asyncio.run(scenario())
        finally:
            P(socket_path).unlink(missing_ok=True)

        pending = hub.db.list_pending_interactions()
        ids = {p["interaction_id"] for p in pending}
        assert iid in ids, f"must surface under text_proxy enforce; reply={reply}"

    def test_socket_path_surfaces_approval_even_when_blocked(self, db_path: Path):
        """End-to-end through AgentHub socket: blocked + approval_needed → pending.

        This drives the real ``_handle_socket_conn`` path — not a reimplementation
        of upsert_interaction — so a regression that moves the early-return
        above the surface block fails this test.
        """
        import json
        import uuid
        from pathlib import Path as P

        socket_path = f"/tmp/shannon_ask_{uuid.uuid4().hex[:8]}.sock"
        prompt = _verbose_prompt(120)
        iid = "ask-must-surface-e2e"

        async def scenario():
            hub = sg.AgentHub(db_path=db_path)
            hub._lock = asyncio.Lock()
            hub._shutdown = asyncio.Event()
            server = await asyncio.start_unix_server(
                hub._handle_socket_conn, path=socket_path
            )
            async with server:
                reader, writer = await asyncio.open_unix_connection(socket_path)
                writer.write(
                    (json.dumps({"agent_id": "science", "task_id": "t1"}) + "\n").encode()
                )
                await writer.drain()
                await reader.readline()  # welcome
                body = {
                    "agent_id": "science",
                    "task_id": "t1",
                    "message_type": "approval_needed",
                    "message_id": iid,
                    "payload": {
                        "prompt": prompt,
                        "approval_needed": True,
                        "interaction_id": iid,
                    },
                    "shannon_H": 0.0,
                    "confidence": 1.0,
                }
                writer.write((json.dumps(body) + "\n").encode())
                await writer.drain()
                reply = json.loads((await reader.readline()).decode())
                writer.close()
                return reply, hub

        try:
            reply, hub = asyncio.run(scenario())
        finally:
            P(socket_path).unlink(missing_ok=True)

        assert "error" not in reply or reply.get("decision") is not None
        pending = hub.db.list_pending_interactions()
        ids = {p["interaction_id"] for p in pending}
        assert iid in ids, (
            f"socket path must persist pending ask; reply={reply} pending={ids}"
        )
        # Prompt should still be human-readable; blocked adds a gate-held prefix.
        row = next(p for p in pending if p["interaction_id"] == iid)
        assert "approval_token" in row.get("prompt", "") or prompt[:20] in row.get(
            "prompt", ""
        )


class TestObserveAgentDoesNotClaimLive:
    def test_http_observe_sets_disconnected(self, hub: sg.AgentHub):
        """⌘D / HTTP must not clear disconnected_at (fake live)."""
        now = time.time_ns()
        hub.db.observe_agent(
            "cursor",
            now,
            entropy_score=3.2,
            task_id="ingest",
            task_summary="Working in Cursor",
            status="observed",
        )
        import sqlite3

        with sqlite3.connect(hub.db.db_path) as conn:
            row = conn.execute(
                "SELECT status, disconnected_at, entropy_score, auth_method "
                "FROM agents WHERE agent_id = ?",
                ("cursor",),
            ).fetchone()
        assert row is not None
        status, disconnected_at, entropy, auth = row
        assert status == "observed"
        assert disconnected_at is not None, "observe must not claim open connection"
        assert abs(entropy - 3.2) < 1e-9
        assert auth == "http_observe"

    def test_socket_upsert_clears_disconnected(self, hub: sg.AgentHub):
        now = time.time_ns()
        hub.db.observe_agent("science", now, 2.0, "t")
        hub.db.upsert_agent("science", "active", now + 1)
        import sqlite3

        with sqlite3.connect(hub.db.db_path) as conn:
            disc = conn.execute(
                "SELECT disconnected_at FROM agents WHERE agent_id = 'science'"
            ).fetchone()[0]
        assert disc is None, "real socket registration claims live"


class TestCursorIdentity:
    def test_cursor_and_vscode_are_valid_agents(self):
        from agent_identity import IDENTITIES

        assert "cursor" in IDENTITIES
        assert "vscode" in IDENTITIES
        assert "cursor" in sg.VALID_AGENTS
        assert "vscode" in sg.VALID_AGENTS

    def test_xcode_and_grok_build_are_valid_agents(self):
        from agent_identity import IDENTITIES

        assert "xcode" in IDENTITIES
        assert "xcode" in sg.VALID_AGENTS
        assert IDENTITIES["xcode"].id == "xcode"
        assert "claude" not in IDENTITIES["xcode"].display_name.lower()
        assert "grok_build" in IDENTITIES
        assert "grok_build" in sg.VALID_AGENTS
