"""Regression tests for `agent_manager monitor` roster reporting.

`monitor` is the documented precondition for the dual-heavy-owner rule: an
agent runs it, sees who is online, and refuses to spawn a second
`dataset_runner`. That makes an *empty* roster the single most dangerous value
this code can return, because "nobody is online" is exactly the answer that
green-lights a second heavy owner.

Two distinct ways an empty roster used to be produced without anything being
wrong with the hub:

1. The gate nests the roster under ``data`` (``{"type": "query_response",
   "query_type": "agent_list", "data": {"connected": [...]}}``) but the manager
   read ``connected`` off the top level, so a perfectly good reply decoded to
   [].
2. When the gate accepts the connection but never answers, the send times out
   and yields ``{}``, which decoded to the same [] — and was still reported as
   ``ok: True``.

Both are covered here against a scripted fake gate.
"""

from __future__ import annotations

import json
import os
import socket as _socket
import sys
import threading
import uuid

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import agent_manager as am  # noqa: E402
import agent_protocol as ap  # noqa: E402

# Every test here drives a scripted gate over a real socket. If the transport
# does not bound how long a send waits for its reply, the sender and the
# background receive loop are two readers on one fd and a swallowed reply
# blocks forever — which would hang the suite rather than fail it. Bounded
# transports (those exposing _RESPONSE_TIMEOUT_S) are the only ones that can
# exercise these paths safely.
pytestmark = pytest.mark.skipif(
    not hasattr(ap.AgentClient, "_RESPONSE_TIMEOUT_S"),
    reason="transport has no bounded response wait; fake-gate tests would hang",
)


@pytest.fixture
def gate_socket_path():
    # /tmp + short uuid, not tmp_path: macOS pytest tmp dirs exceed the
    # 104-byte sun_path limit for *bound* sockets.
    path = f"/tmp/shannon-mon-test-{uuid.uuid4().hex[:8]}.sock"
    yield path
    if os.path.exists(path):
        os.unlink(path)


def _fake_gate(path, *, answer_queries: bool, connected=("dataset_runner",)):
    """Bind a gate that welcomes, then optionally answers every query.

    With answer_queries=False the gate stays connected and silent — the
    "accepts but never replies" case that must not hang or masquerade as an
    empty roster.
    """
    srv = _socket.socket(_socket.AF_UNIX, _socket.SOCK_STREAM)
    srv.bind(path)
    srv.listen(1)

    def run():
        conn, _ = srv.accept()
        reader = conn.makefile("rb")
        reg = json.loads(reader.readline())
        conn.sendall(
            json.dumps({"type": "welcome", "agent_id": reg["agent_id"]}).encode() + b"\n"
        )
        while True:
            line = reader.readline()
            if not line:
                break
            if not answer_queries:
                continue
            env = json.loads(line)
            qt = (env.get("payload") or {}).get("query_type")
            if qt == "agent_list":
                # Exactly the shape shannon_gate.py emits.
                body = {"connected": list(connected), "count": len(connected)}
            elif qt == "recent_messages":
                body = []
            else:
                body = {}
            conn.sendall(
                json.dumps(
                    {"type": "query_response", "query_type": qt, "data": body}
                ).encode()
                + b"\n"
            )
        try:
            conn.close()
        finally:
            srv.close()

    t = threading.Thread(target=run, daemon=True)
    t.start()
    return srv


def test_monitor_reports_agents_the_gate_actually_returned(gate_socket_path):
    """A well-formed reply must not decode to an empty roster.

    The roster arrives nested under `data`; reading the top level silently
    yielded [] and would green-light a second heavy owner.
    """
    _fake_gate(gate_socket_path, answer_queries=True, connected=("dataset_runner",))

    mgr = am.AgentManager(socket_path=gate_socket_path)
    out = mgr.monitor(agent_id="claude_code", task_id="t_probe")

    assert out["connected"] == ["dataset_runner"]
    assert out["roster_known"] is True
    assert out["ok"] is True
    assert "dataset_runner" in out["report"]


@pytest.mark.skipif(
    not hasattr(ap.AgentClient, "_RESPONSE_TIMEOUT_S"),
    reason=(
        "transport has no bounded response wait, so a silent gate blocks "
        "forever and this case cannot be exercised without hanging the suite"
    ),
)
def test_monitor_does_not_report_a_confident_empty_roster_on_timeout(
    gate_socket_path, monkeypatch
):
    """A silent gate must be reported as UNKNOWN, never as "nobody online"."""
    monkeypatch.setattr(ap.AgentClient, "_RESPONSE_TIMEOUT_S", 0.5)
    _fake_gate(gate_socket_path, answer_queries=False)

    mgr = am.AgentManager(socket_path=gate_socket_path)
    out = mgr.monitor(agent_id="claude_code", task_id="t_probe")

    assert out["roster_known"] is False
    assert out["ok"] is False
    assert out["connected"] == []
    assert "unknown" in out["report"].lower()


def test_monitor_reports_a_genuinely_empty_roster_as_known(gate_socket_path):
    """An empty roster the gate really did return stays trustworthy."""
    _fake_gate(gate_socket_path, answer_queries=True, connected=())

    mgr = am.AgentManager(socket_path=gate_socket_path)
    out = mgr.monitor(agent_id="claude_code", task_id="t_probe")

    assert out["connected"] == []
    assert out["roster_known"] is True
    assert out["ok"] is True
